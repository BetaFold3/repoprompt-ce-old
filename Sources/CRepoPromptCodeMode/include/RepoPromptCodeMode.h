// Opaque embedded runtime for the experimental `code_mode` executor (plan §6 D3).
//
// One host runs one script once: it owns one QuickJS-ng runtime and context, created, used and
// freed only on its own owner thread. No QuickJS type crosses this header. Cross-thread entry
// points (submit_reply, request_stop) touch only plain host state under the host mutex.
//
// Lifecycle: create -> start -> (dispatch callbacks, replies, optional stop) -> exit callback ->
// join -> outcome -> destroy. destroy is allowed only before a successful start or after join.
#ifndef REPOPROMPT_CODE_MODE_H
#define REPOPROMPT_CODE_MODE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Final human-readable tool result cap, footer included.
#define RPCM_FINAL_RESULT_BYTES 32768u
/// Part of the final cap reserved for the executor's failure footer; guest output gets the rest.
#define RPCM_RESULT_METADATA_RESERVE_BYTES 4096u
/// Child attempts per script, automatic retries included.
#define RPCM_MAX_ATTEMPTS 32u
/// Failure code storage per failed call (NUL included).
#define RPCM_FAILURE_CODE_BYTES 64u
/// Script error message storage (NUL included).
#define RPCM_MESSAGE_BYTES 1024u

typedef struct rpcm_host rpcm_host;

typedef enum {
    RPCM_TOOL_READ_FILE = 0,
    RPCM_TOOL_FILE_SEARCH = 1,
    RPCM_TOOL_GET_CODE_STRUCTURE = 2,
    RPCM_TOOL_GET_FILE_TREE = 3
} rpcm_tool;

/// Every field must be > 0 and <= its production value; production values are the plan limits.
typedef struct {
    uint32_t wall_ms;        // 60 000: wall time, child waits and retries included
    uint32_t cpu_ms;         // 2 000: guest thread CPU, counted only while guest code can run
    uint32_t heap_bytes;     // 64 MiB QuickJS heap
    uint32_t stack_bytes;    // 1 MiB QuickJS stack guard
    uint32_t script_bytes;   // 32 KiB UTF-8 script
    uint32_t args_bytes;     // 64 KiB serialized arguments per call
    uint32_t result_bytes;   // 2 MiB serialized child result per call
    uint32_t output_bytes;   // guest output: RPCM_FINAL_RESULT_BYTES - RPCM_RESULT_METADATA_RESERVE_BYTES
    uint32_t max_attempts;   // 32 child attempts, automatic retries included
    uint32_t max_in_flight;  // 2 children dispatched at once, all tools together
} rpcm_limits;

rpcm_limits rpcm_production_limits(void);

typedef enum {
    RPCM_CREATE_OK = 0,
    RPCM_CREATE_INVALID_LIMITS,
    RPCM_CREATE_SCRIPT_TOO_LARGE,
    RPCM_CREATE_SCRIPT_NOT_UTF8,
    RPCM_CREATE_ALLOCATION_FAILED
} rpcm_create_status;

/// Copies the script; the host is inert until started.
rpcm_create_status rpcm_host_create(const char *script, size_t script_len, const rpcm_limits *limits,
                                    rpcm_host **out_host);

/// Called on the owner thread, never under the host mutex, once per dispatched attempt (1 or 2).
/// `args_json` is borrowed for the duration of the call: copy it, never block, never call back
/// into the host synchronously except submit_reply/request_stop (both nonblocking).
typedef void (*rpcm_dispatch_fn)(void *context, uint32_t call_id, uint32_t attempt, rpcm_tool tool,
                                 const char *args_json, size_t args_len);
/// Called once on the owner thread after every QuickJS value, the context and the runtime are
/// freed, immediately before the thread returns. The host is still valid; join may then be called
/// from another thread and returns promptly. Never call join from inside this callback.
typedef void (*rpcm_exit_fn)(void *context);

/// Starts exactly one owner thread. Returns 0, or an errno value when no thread was started (the
/// host may then be destroyed). A second start returns EALREADY.
int rpcm_host_start(rpcm_host *host, rpcm_dispatch_fn dispatch, rpcm_exit_fn on_exit, void *context);

typedef enum {
    RPCM_REPLY_SUCCESS = 0,
    RPCM_REPLY_FAILURE = 1,
    /// A typed transient failure: retried once with the same arguments if the attempt budget
    /// allows, otherwise final like RPCM_REPLY_FAILURE.
    RPCM_REPLY_RETRYABLE_FAILURE = 2
} rpcm_disposition;

typedef enum {
    RPCM_SUBMIT_ACCEPTED = 0,
    /// Stale, duplicate, unknown call/attempt, or the host stopped accepting replies.
    RPCM_SUBMIT_NOT_ACCEPTED,
    RPCM_SUBMIT_INVALID
} rpcm_submit_status;

/// Thread-safe and nonblocking. `payload_json` is a JSON object: success `{data|text, isError:false}`,
/// failure `{isError:true, error, code?, text?}`; it is copied. A payload over `result_bytes` is
/// accepted as a `child_result_too_large` failure. `failure_code` (nullable, NUL-terminated) names
/// a failure in the outcome; it is truncated to RPCM_FAILURE_CODE_BYTES - 1 bytes.
rpcm_submit_status rpcm_host_submit_reply(rpcm_host *host, uint32_t call_id, uint32_t attempt,
                                          rpcm_disposition disposition, const char *payload_json,
                                          size_t payload_len, const char *failure_code);

/// Thread-safe, idempotent, nonblocking: marks the run cancelled, stops accepting replies and
/// dispatching children, and wakes the owner, which interrupts guest code and tears down.
void rpcm_host_request_stop(rpcm_host *host);

typedef enum {
    RPCM_STATUS_SUCCESS = 0,
    RPCM_STATUS_SCRIPT_ERROR,
    RPCM_STATUS_TIMEOUT,
    RPCM_STATUS_CANCELLED,
    RPCM_STATUS_LIMIT_EXCEEDED,
    RPCM_STATUS_RUNTIME_ERROR
} rpcm_status;

typedef enum {
    RPCM_REASON_NONE = 0,
    RPCM_REASON_SCRIPT_EXCEPTION,
    RPCM_REASON_UNSETTLEABLE_PROMISE,
    RPCM_REASON_WALL_TIME,
    RPCM_REASON_CANCELLED,
    RPCM_REASON_CPU_TIME,
    RPCM_REASON_MEMORY,
    RPCM_REASON_STACK,
    RPCM_REASON_OUTPUT,
    RPCM_REASON_CALLS,
    RPCM_REASON_HOST_ALLOCATION,
    RPCM_REASON_ENGINE_INIT
} rpcm_reason;

typedef struct {
    uint32_t call_id;
    rpcm_tool tool;
    uint32_t attempts;
    char code[RPCM_FAILURE_CODE_BYTES];
} rpcm_failed_call;

/// Plain snapshot owned by the host; valid from join until destroy.
/// Invariant: calls == completed + queued_at_stop + in_flight_at_stop; failed <= completed.
typedef struct {
    rpcm_status status;
    rpcm_reason reason;
    const char *output;  // valid UTF-8, entries joined by '\n', at most output_bytes
    size_t output_len;
    const char *message; // script error text (valid UTF-8, bounded), or empty
    size_t message_len;
    uint32_t calls;              // logical calls admitted
    uint32_t attempts;           // attempts dispatched to the host
    uint32_t completed;          // calls whose final reply was accepted
    uint32_t failed;             // completed calls whose final reply was a failure
    uint32_t queued_at_stop;
    uint32_t in_flight_at_stop;
    uint32_t retries;            // automatic retries admitted
    uint32_t max_in_flight_observed;
    uint32_t failed_call_count;
    rpcm_failed_call failed_calls[RPCM_MAX_ATTEMPTS];
    double guest_cpu_ms;
    double wall_ms;
} rpcm_outcome;

/// Blocking, single caller, after start. Joins the owner thread. Returns the snapshot.
const rpcm_outcome *rpcm_host_join(rpcm_host *host);

/// Progress the owner thread last published: committed output length, counts and terminal failed
/// calls. Published under the host mutex at consistent points (output commit, call admission,
/// dispatch, reply processing, final outcome), so the rpcm_outcome invariants hold with `queued`
/// and `in_flight` counted at publication.
typedef struct {
    size_t output_len;
    uint32_t calls;
    uint32_t attempts;
    uint32_t completed;
    uint32_t failed;
    uint32_t queued;
    uint32_t in_flight;
    uint32_t retries;
    uint32_t failed_call_count;
    rpcm_failed_call failed_calls[RPCM_MAX_ATTEMPTS];
} rpcm_progress;

/// Thread-safe and nonblocking: holds only the host mutex briefly and never waits for guest code
/// or the owner thread. Valid any time between create and destroy, including while the owner
/// runs. Copies the published progress into `progress` and up to `output_capacity` bytes of the
/// committed output prefix (bytes the owner never rewrites) into `output`. Returns the number of
/// output bytes copied; pass at least `output_bytes` so a UTF-8 sequence is never cut.
size_t rpcm_host_snapshot(rpcm_host *host, rpcm_progress *progress, char *output, size_t output_capacity);

/// Frees the host. Returns false and frees nothing if the host was started and not yet joined.
bool rpcm_host_destroy(rpcm_host *host);

#ifdef __cplusplus
}
#endif

#endif
