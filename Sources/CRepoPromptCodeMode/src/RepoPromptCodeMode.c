// Embedded QuickJS-ng host for the experimental `code_mode` executor (plan §6 D3).
// See include/RepoPromptCodeMode.h for the contract. Every QuickJS call happens on the host's
// owner thread; other threads only touch the mailbox fields marked "mu" under `mu`.
#include "RepoPromptCodeMode.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "quickjs.h"

static const char *const kToolNames[4] = {"read_file", "file_search", "get_code_structure", "get_file_tree"};
static const char kSourcePrefix[] = "(async () => {\n";
static const char kSourceSuffix[] = "\n})";
static const size_t kOwnerThreadStackBytes = 8u << 20;

rpcm_limits rpcm_production_limits(void) {
    rpcm_limits limits = {
        .wall_ms = 60000u,
        .cpu_ms = 2000u,
        .heap_bytes = 64u << 20,
        .stack_bytes = 1u << 20,
        .script_bytes = 32u << 10,
        .args_bytes = 64u << 10,
        .result_bytes = 2u << 20,
        .output_bytes = RPCM_FINAL_RESULT_BYTES - RPCM_RESULT_METADATA_RESERVE_BYTES,
        .max_attempts = RPCM_MAX_ATTEMPTS,
        .max_in_flight = 2u,
    };
    return limits;
}

typedef enum { CALL_QUEUED = 1, CALL_IN_FLIGHT, CALL_DONE } call_state;
typedef enum { PHASE_RUNNING, PHASE_DRAINING, PHASE_TEARDOWN } run_phase;

typedef struct {
    // Owner-only after admission.
    rpcm_tool tool;
    char *args;
    size_t args_len;
    bool allow_error;
    bool has_resolvers;
    JSValue resolve;
    JSValue reject;
    // Written by the owner under mu; read by submit_reply under mu.
    uint32_t attempt;
    call_state state;
    // Mailbox (mu).
    bool reply_ready;
    rpcm_disposition disposition;
    char *payload;
    size_t payload_len;
    char code[RPCM_FAILURE_CODE_BYTES];
} call_t;

struct rpcm_host {
    rpcm_limits limits;
    char *source;
    size_t source_len;
    char *output;
    size_t output_len;
    uint32_t output_entries;
    char *scratch;
    char message[RPCM_MESSAGE_BYTES];
    size_t message_len;

    pthread_mutex_t mu;
    pthread_cond_t cv;
    pthread_t thread;
    bool started;
    bool joined;
    rpcm_dispatch_fn dispatch;
    rpcm_exit_fn on_exit;
    void *context;
    atomic_bool cancel_requested;

    // mu
    bool accepting;
    uint32_t ncalls;
    call_t calls[RPCM_MAX_ATTEMPTS];
    // mu; written only by the owner (publish_progress), read by rpcm_host_snapshot. Output bytes
    // before progress.output_len are committed and never rewritten (the owner only appends).
    rpcm_progress progress;

    // Owner thread only.
    JSRuntime *rt;
    JSContext *ctx;
    run_phase phase;
    rpcm_reason stop_reason;
    rpcm_reason script_reason;
    double t0_ms;
    double deadline_ms;
    double cpu_acc_ms;
    double cpu_enter_ms;
    bool in_guest;
    uint32_t retries;
    uint32_t in_flight;
    uint32_t attempts_dispatched;
    uint32_t max_in_flight_seen;
    uint32_t completed;
    uint32_t failed;
    rpcm_outcome outcome;
};

static uint32_t count_state(const rpcm_host *h, call_state state);

/// Owner thread, mu held: publishes committed progress for rpcm_host_snapshot. Call only at points
/// where the counts are mutually consistent.
static void publish_progress_locked(rpcm_host *h) {
    rpcm_progress *p = &h->progress;
    p->output_len = h->output_len;
    p->calls = h->ncalls;
    p->attempts = h->attempts_dispatched;
    p->completed = h->completed;
    p->failed = h->failed;
    p->queued = count_state(h, CALL_QUEUED);
    p->in_flight = count_state(h, CALL_IN_FLIGHT);
    p->retries = h->retries;
    uint32_t count = h->outcome.failed_call_count;
    if (count > p->failed_call_count) {
        memcpy(&p->failed_calls[p->failed_call_count], &h->outcome.failed_calls[p->failed_call_count],
               (count - p->failed_call_count) * sizeof(rpcm_failed_call));
        p->failed_call_count = count;
    }
}

static void publish_progress(rpcm_host *h) {
    pthread_mutex_lock(&h->mu);
    publish_progress_locked(h);
    pthread_mutex_unlock(&h->mu);
}

// MARK: - Time and guest CPU accounting

static double mono_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

static double thread_cpu_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

/// Starts counting guest CPU unless already counting; returns whether this call started it.
static bool guest_enter(rpcm_host *h) {
    if (h->in_guest) return false;
    h->cpu_enter_ms = thread_cpu_ms();
    h->in_guest = true;
    return true;
}

static void guest_leave(rpcm_host *h, bool entered) {
    if (!entered || !h->in_guest) return;
    h->cpu_acc_ms += thread_cpu_ms() - h->cpu_enter_ms;
    h->in_guest = false;
}

static double guest_cpu_ms(const rpcm_host *h) {
    return h->cpu_acc_ms + (h->in_guest ? thread_cpu_ms() - h->cpu_enter_ms : 0);
}

/// Owner thread: records the first stop reason (cancel, wall, guest CPU) and reports any stop.
static bool check_stop(rpcm_host *h) {
    if (h->stop_reason != RPCM_REASON_NONE) return true;
    if (atomic_load(&h->cancel_requested)) {
        h->stop_reason = RPCM_REASON_CANCELLED;
    } else if (mono_ms() >= h->deadline_ms) {
        h->stop_reason = RPCM_REASON_WALL_TIME;
    } else if (guest_cpu_ms(h) > (double)h->limits.cpu_ms) {
        h->stop_reason = RPCM_REASON_CPU_TIME;
    }
    return h->stop_reason != RPCM_REASON_NONE;
}

static int interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    return check_stop((rpcm_host *)opaque) ? 1 : 0;
}

static const char *reason_text(rpcm_reason reason) {
    switch (reason) {
    case RPCM_REASON_WALL_TIME: return "wall time limit exceeded";
    case RPCM_REASON_CANCELLED: return "cancelled";
    case RPCM_REASON_CPU_TIME: return "CPU time limit exceeded";
    case RPCM_REASON_MEMORY: return "memory limit exceeded";
    case RPCM_REASON_STACK: return "stack limit exceeded";
    case RPCM_REASON_OUTPUT: return "output limit exceeded";
    case RPCM_REASON_CALLS: return "nested tool call limit exceeded";
    case RPCM_REASON_HOST_ALLOCATION: return "host allocation failed";
    case RPCM_REASON_UNSETTLEABLE_PROMISE: return "script is awaiting a promise that can never settle";
    default: return "stopped";
    }
}

/// Throws an uncatchable error naming the stop reason: guest code cannot catch it and continue.
static JSValue throw_stop(JSContext *ctx, rpcm_host *h) {
    JSValue error = JS_NewError(ctx);
    if (JS_IsException(error)) return JS_EXCEPTION;
    JS_DefinePropertyValueStr(ctx, error, "message", JS_NewString(ctx, reason_text(h->stop_reason)),
                              JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_SetUncatchableError(ctx, error);
    return JS_Throw(ctx, error);
}

// MARK: - UTF-8

/// Length of the valid UTF-8 sequence at `s`, or 0 when invalid (overlong, surrogate, > U+10FFFF).
static size_t utf8_sequence_length(const unsigned char *s, size_t n) {
    unsigned c = s[0];
    size_t length;
    unsigned minimum;
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) { length = 2; minimum = 0x80; }
    else if ((c & 0xF0) == 0xE0) { length = 3; minimum = 0x800; }
    else if ((c & 0xF8) == 0xF0) { length = 4; minimum = 0x10000; }
    else return 0;
    if (length > n) return 0;
    unsigned cp = c & (0x7Fu >> length);
    for (size_t i = 1; i < length; i++) {
        if ((s[i] & 0xC0) != 0x80) return 0;
        cp = (cp << 6) | (s[i] & 0x3F);
    }
    if (cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
    return length;
}

/// Bytes consumed by one U+FFFD replacement: a whole three-byte form (such as an encoded lone
/// surrogate) or a single byte.
static size_t utf8_invalid_length(const unsigned char *s, size_t n) {
    if (s[0] >= 0xE0 && s[0] < 0xF0 && n >= 3 && (s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80) return 3;
    return 1;
}

static bool utf8_is_valid(const char *s, size_t n) {
    const unsigned char *u = (const unsigned char *)s;
    for (size_t i = 0; i < n;) {
        size_t length = utf8_sequence_length(u + i, n - i);
        if (length == 0) return false;
        i += length;
    }
    return true;
}

/// Copies `s` with every invalid sequence replaced by U+FFFD, writing at most `capacity` bytes
/// and never splitting a character. Returns the bytes written; `*consumed_all` reports whether
/// the whole input fit. A NULL `dst` only measures.
static size_t utf8_sanitized_copy(char *dst, size_t capacity, const char *s, size_t n, bool *consumed_all) {
    static const char replacement[3] = {(char)0xEF, (char)0xBF, (char)0xBD};
    const unsigned char *u = (const unsigned char *)s;
    size_t written = 0;
    size_t i = 0;
    while (i < n) {
        size_t length = utf8_sequence_length(u + i, n - i);
        const char *piece = s + i;
        size_t piece_len = length;
        size_t advance = length;
        if (length == 0) {
            piece = replacement;
            piece_len = 3;
            advance = utf8_invalid_length(u + i, n - i);
        }
        if (written + piece_len > capacity) break;
        if (dst) memcpy(dst + written, piece, piece_len);
        written += piece_len;
        i += advance;
    }
    if (consumed_all) *consumed_all = (i >= n);
    return written;
}

static void set_message(rpcm_host *h, const char *s, size_t n) {
    h->message_len = utf8_sanitized_copy(h->message, sizeof h->message - 1, s, n, NULL);
    h->message[h->message_len] = '\0';
}

static void copy_code(char *dst, const char *code) {
    size_t n = code ? strnlen(code, RPCM_FAILURE_CODE_BYTES - 1) : 0;
    n = utf8_sanitized_copy(dst, RPCM_FAILURE_CODE_BYTES - 1, code ? code : "", n, NULL);
    dst[n] = '\0';
}

// MARK: - Output

/// Adds `s` to the pending entry in scratch. Returns -1 (nothing added) when the entry, its
/// separator, and the accepted output would exceed the guest output limit.
static int entry_add(rpcm_host *h, size_t *entry_len, const char *s, size_t n) {
    size_t used = h->output_len + (h->output_entries ? 1 : 0) + *entry_len;
    size_t limit = h->limits.output_bytes;
    if (used > limit) return -1;
    bool all = false;
    size_t written = utf8_sanitized_copy(h->scratch + *entry_len, limit - used, s, n, &all);
    if (!all) return -1;
    *entry_len += written;
    return 0;
}

/// Appends the pending entry as one complete, separately committed output entry. The whole entry
/// and its separator are checked against the output limit before anything is written, so empty
/// entries (which never pass through entry_add) cannot overrun the buffer or its final NUL slot.
/// Returns false and writes nothing when they do not fit; the caller must then end the run with
/// RPCM_REASON_OUTPUT. Entries committed earlier are kept.
static bool entry_commit(rpcm_host *h, size_t entry_len) {
    size_t limit = h->limits.output_bytes;
    size_t separator = h->output_entries ? 1 : 0;
    if (h->output_len > limit || separator > limit - h->output_len ||
        entry_len > limit - h->output_len - separator) {
        return false;
    }
    if (separator) h->output[h->output_len++] = '\n';
    memcpy(h->output + h->output_len, h->scratch, entry_len);
    h->output_len += entry_len;
    h->output_entries++;
    publish_progress(h);
    return true;
}

/// Ends the run because guest output would exceed its limit; the first stop reason wins.
static void stop_for_output(rpcm_host *h) {
    if (h->stop_reason == RPCM_REASON_NONE) h->stop_reason = RPCM_REASON_OUTPUT;
}

/// Formats one value into the pending entry: strings verbatim, other values through the C JSON
/// API (never the guest's `JSON`), undefined/functions as nothing. Promises are rejected.
/// Returns 0, -1 with a pending JS exception, or -2 when the output limit would be exceeded.
static int entry_add_value(rpcm_host *h, JSContext *ctx, JSValueConst value, size_t *entry_len, const char *who) {
    if (JS_IsPromise(value)) {
        JS_ThrowTypeError(ctx, "%s: await the value first; a promise cannot be printed", who);
        return -1;
    }
    JSValue string;
    if (JS_IsString(value)) {
        string = JS_DupValue(ctx, value);
    } else {
        string = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_NewInt32(ctx, 1));
        if (JS_IsException(string)) return -1;
    }
    if (JS_IsUndefined(string)) return 0;
    size_t n = 0;
    const char *c = JS_ToCStringLen(ctx, &n, string);
    JS_FreeValue(ctx, string);
    if (!c) return -1;
    int rc = entry_add(h, entry_len, c, n);
    JS_FreeCString(ctx, c);
    return rc == 0 ? 0 : -2;
}

static JSValue js_text(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    rpcm_host *h = JS_GetContextOpaque(ctx);
    if (check_stop(h)) return throw_stop(ctx, h);
    size_t entry_len = 0;
    int rc = entry_add_value(h, ctx, argc > 0 ? argv[0] : JS_UNDEFINED, &entry_len, "text()");
    if (rc == -1) return JS_EXCEPTION;
    if (rc == -2 || !entry_commit(h, entry_len)) {
        stop_for_output(h);
        return throw_stop(ctx, h);
    }
    return JS_UNDEFINED;
}

static JSValue js_console_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    rpcm_host *h = JS_GetContextOpaque(ctx);
    if (check_stop(h)) return throw_stop(ctx, h);
    size_t entry_len = 0;
    for (int i = 0; i < argc; i++) {
        int rc = 0;
        if (i > 0 && entry_add(h, &entry_len, " ", 1) != 0) rc = -2;
        if (rc == 0) rc = entry_add_value(h, ctx, argv[i], &entry_len, "console.log()");
        if (rc == -1) return JS_EXCEPTION;
        if (rc == -2) {
            stop_for_output(h);
            return throw_stop(ctx, h);
        }
    }
    if (!entry_commit(h, entry_len)) {
        stop_for_output(h);
        return throw_stop(ctx, h);
    }
    return JS_UNDEFINED;
}

// MARK: - Tool bridge

static JSValue js_tool(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic) {
    (void)this_val;
    rpcm_host *h = JS_GetContextOpaque(ctx);
    const char *name = kToolNames[magic];
    if (check_stop(h)) return throw_stop(ctx, h);

    JSValueConst arguments = argc > 0 ? argv[0] : JS_UNDEFINED;
    char *args = NULL;
    size_t args_len = 0;
    if (JS_IsUndefined(arguments)) {
        args = malloc(3);
        if (!args) goto allocation_failed;
        memcpy(args, "{}", 3);
        args_len = 2;
    } else {
        if (!JS_IsObject(arguments) || JS_IsArray(arguments) || JS_IsFunction(ctx, arguments)) {
            return JS_ThrowTypeError(ctx, "tools.%s: arguments must be a plain object", name);
        }
        // Getters, proxies and toJSON run here as guest code, inside the guest CPU/wall budget.
        JSValue json = JS_JSONStringify(ctx, arguments, JS_UNDEFINED, JS_UNDEFINED);
        if (JS_IsException(json)) return JS_EXCEPTION;
        if (!JS_IsString(json)) {
            JS_FreeValue(ctx, json);
            return JS_ThrowTypeError(ctx, "tools.%s: arguments must serialize to a JSON object", name);
        }
        size_t n = 0;
        const char *c = JS_ToCStringLen(ctx, &n, json);
        JS_FreeValue(ctx, json);
        if (!c) return JS_EXCEPTION;
        if (n == 0 || c[0] != '{') {
            JS_FreeCString(ctx, c);
            return JS_ThrowTypeError(ctx, "tools.%s: arguments must serialize to a JSON object", name);
        }
        if (n > h->limits.args_bytes) {
            JS_FreeCString(ctx, c);
            return JS_ThrowRangeError(ctx, "tools.%s: arguments exceed %u bytes", name, h->limits.args_bytes);
        }
        args = malloc(n + 1);
        if (!args) {
            JS_FreeCString(ctx, c);
            goto allocation_failed;
        }
        memcpy(args, c, n);
        args[n] = '\0';
        args_len = n;
        JS_FreeCString(ctx, c);
    }

    bool allow_error = false;
    if (argc > 1 && !JS_IsUndefined(argv[1])) {
        if (!JS_IsObject(argv[1])) {
            free(args);
            return JS_ThrowTypeError(ctx, "tools.%s: options must be an object", name);
        }
        JSValue flag = JS_GetPropertyStr(ctx, argv[1], "allowError");
        if (JS_IsException(flag)) {
            free(args);
            return JS_EXCEPTION;
        }
        int truthy = JS_ToBool(ctx, flag);
        JS_FreeValue(ctx, flag);
        if (truthy < 0) {
            free(args);
            return JS_EXCEPTION;
        }
        allow_error = truthy != 0;
    }

    if (check_stop(h)) {
        free(args);
        return throw_stop(ctx, h);
    }
    if (h->ncalls + h->retries >= h->limits.max_attempts) {
        // Ends the whole run even if the script catches the exception.
        free(args);
        h->stop_reason = RPCM_REASON_CALLS;
        return throw_stop(ctx, h);
    }
    JSValue funcs[2];
    JSValue promise = JS_NewPromiseCapability(ctx, funcs);
    if (JS_IsException(promise)) {
        free(args);
        return JS_EXCEPTION;
    }
    pthread_mutex_lock(&h->mu);
    call_t *call = &h->calls[h->ncalls];
    call->tool = (rpcm_tool)magic;
    call->args = args;
    call->args_len = args_len;
    call->allow_error = allow_error;
    call->has_resolvers = true;
    call->resolve = funcs[0];
    call->reject = funcs[1];
    call->attempt = 1;
    call->state = CALL_QUEUED;
    call->reply_ready = false;
    call->payload = NULL;
    call->payload_len = 0;
    call->code[0] = '\0';
    h->ncalls++;
    publish_progress_locked(h);
    pthread_mutex_unlock(&h->mu);
    return promise;

allocation_failed:
    h->stop_reason = RPCM_REASON_HOST_ALLOCATION;
    return throw_stop(ctx, h);
}

/// Owner thread: hands queued attempts to the dispatcher while capacity remains.
static void dispatch_ready(rpcm_host *h) {
    for (uint32_t i = 0; i < h->ncalls; i++) {
        if (h->stop_reason != RPCM_REASON_NONE || atomic_load(&h->cancel_requested)) return;
        if (h->in_flight >= h->limits.max_in_flight) return;
        call_t *call = &h->calls[i];
        if (call->state != CALL_QUEUED) continue;
        h->in_flight++;
        if (h->in_flight > h->max_in_flight_seen) h->max_in_flight_seen = h->in_flight;
        h->attempts_dispatched++;
        pthread_mutex_lock(&h->mu);
        call->state = CALL_IN_FLIGHT;
        uint32_t attempt = call->attempt;
        publish_progress_locked(h);
        pthread_mutex_unlock(&h->mu);
        h->dispatch(h->context, i + 1, attempt, call->tool, call->args, call->args_len);
    }
}

static const char *failure_text(const char *code) {
    if (!strcmp(code, "child_result_too_large")) return "tool result exceeds the per-call result limit";
    if (!strcmp(code, "host_allocation_failure")) return "the host could not store the tool result";
    if (!strcmp(code, "bridge_malformed_reply")) return "malformed tool reply";
    return "tool call failed";
}

static void record_failed_call(rpcm_host *h, uint32_t index, const char *code, uint32_t attempts) {
    rpcm_outcome *o = &h->outcome;
    if (o->failed_call_count >= RPCM_MAX_ATTEMPTS) return;
    rpcm_failed_call *record = &o->failed_calls[o->failed_call_count++];
    record->call_id = index + 1;
    record->tool = h->calls[index].tool;
    record->attempts = attempts;
    copy_code(record->code, code);
}

/// `{isError: true, error, code}` for a failure that carried no usable payload.
static JSValue make_failure_object(JSContext *ctx, const char *code) {
    JSValue object = JS_NewObject(ctx);
    if (JS_IsException(object)) return object;
    if (JS_DefinePropertyValueStr(ctx, object, "isError", JS_TRUE, JS_PROP_C_W_E) < 0 ||
        JS_DefinePropertyValueStr(ctx, object, "error", JS_NewString(ctx, failure_text(code)), JS_PROP_C_W_E) < 0 ||
        JS_DefinePropertyValueStr(ctx, object, "code", JS_NewString(ctx, code), JS_PROP_C_W_E) < 0) {
        JS_FreeValue(ctx, object);
        return JS_EXCEPTION;
    }
    return object;
}

/// An Error whose enumerable fields (message, code, callID, result) survive serialization.
static JSValue make_failure_error(JSContext *ctx, uint32_t call_id, JSValueConst result, const char *code) {
    JSValue message = JS_GetPropertyStr(ctx, result, "error");
    if (JS_IsException(message)) return JS_EXCEPTION;
    if (!JS_IsString(message)) {
        JS_FreeValue(ctx, message);
        message = JS_NewString(ctx, failure_text(code));
    }
    JSValue code_value = JS_GetPropertyStr(ctx, result, "code");
    if (JS_IsException(code_value)) {
        JS_FreeValue(ctx, message);
        return JS_EXCEPTION;
    }
    if (!JS_IsString(code_value)) {
        JS_FreeValue(ctx, code_value);
        code_value = JS_NewString(ctx, code);
    }
    JSValue error = JS_NewError(ctx);
    if (JS_IsException(error)) {
        JS_FreeValue(ctx, message);
        JS_FreeValue(ctx, code_value);
        return JS_EXCEPTION;
    }
    if (JS_DefinePropertyValueStr(ctx, error, "message", message, JS_PROP_C_W_E) < 0 ||
        JS_DefinePropertyValueStr(ctx, error, "code", code_value, JS_PROP_C_W_E) < 0 ||
        JS_DefinePropertyValueStr(ctx, error, "callID", JS_NewUint32(ctx, call_id), JS_PROP_C_W_E) < 0 ||
        JS_DefinePropertyValueStr(ctx, error, "result", JS_DupValue(ctx, result), JS_PROP_C_W_E) < 0) {
        JS_FreeValue(ctx, error);
        return JS_EXCEPTION;
    }
    return error;
}

/// Clears a pending exception raised by host-side work; an exhausted heap becomes the stop reason.
static void discard_host_exception(rpcm_host *h) {
    JSValue exception = JS_GetException(h->ctx);
    JS_FreeValue(h->ctx, exception);
    if (h->stop_reason == RPCM_REASON_NONE) h->stop_reason = RPCM_REASON_MEMORY;
}

/// Owner thread: final accounting for one logical call and, while guest code may still run,
/// settling its promise (reject by default, resolve with the failure under allowError).
static void complete_call(rpcm_host *h, uint32_t index, bool success, const char *payload, size_t payload_len,
                          const char *reply_code, uint32_t attempts) {
    call_t *call = &h->calls[index];
    JSContext *ctx = h->ctx;
    char code[RPCM_FAILURE_CODE_BYTES];
    copy_code(code, reply_code && reply_code[0] ? reply_code : "tool_error");
    h->completed++;

    bool settle = call->has_resolvers && h->phase == PHASE_RUNNING && h->stop_reason == RPCM_REASON_NONE;
    bool entered = false;
    JSValue result = JS_UNDEFINED;
    // Host-side parse of our own reply bytes: no guest code runs, so no guest CPU is charged.
    if (settle && payload) {
        result = JS_ParseJSON(ctx, payload, payload_len, "<tool_result>");
        if (JS_IsException(result)) {
            JSValue exception = JS_GetException(ctx);
            JS_FreeValue(ctx, exception);
            result = JS_UNDEFINED;
            if (h->stop_reason != RPCM_REASON_NONE) settle = false;
        }
        if (!JS_IsObject(result)) {
            JS_FreeValue(ctx, result);
            result = JS_UNDEFINED;
            if (success) {
                success = false;
                copy_code(code, "bridge_malformed_reply");
            }
        }
    } else if (settle && success) {
        success = false;
        copy_code(code, "bridge_malformed_reply");
    }

    if (!success) {
        h->failed++;
        record_failed_call(h, index, code, attempts);
    }

    if (settle && h->stop_reason == RPCM_REASON_NONE) {
        // Property reads and `then` lookups during settlement can run guest getters.
        entered = guest_enter(h);
        if (!success && JS_IsUndefined(result)) result = make_failure_object(ctx, code);
        JSValue argument = JS_UNDEFINED;
        JSValue settle_fn = JS_UNDEFINED;
        if (JS_IsException(result)) {
            result = JS_UNDEFINED;
            discard_host_exception(h);
        } else if (!success && !call->allow_error) {
            argument = make_failure_error(ctx, index + 1, result, code);
            settle_fn = call->reject;
        } else {
            argument = JS_DupValue(ctx, result);
            settle_fn = call->resolve;
        }
        if (JS_IsException(argument)) {
            argument = JS_UNDEFINED;
            discard_host_exception(h);
        } else if (!JS_IsUndefined(settle_fn) && h->stop_reason == RPCM_REASON_NONE) {
            JSValue returned = JS_Call(ctx, settle_fn, JS_UNDEFINED, 1, (JSValueConst *)&argument);
            if (JS_IsException(returned)) {
                discard_host_exception(h);
            } else {
                JS_FreeValue(ctx, returned);
            }
        }
        JS_FreeValue(ctx, argument);
    }
    guest_leave(h, entered);
    JS_FreeValue(ctx, result);

    if (call->has_resolvers) {
        JS_FreeValue(ctx, call->resolve);
        JS_FreeValue(ctx, call->reject);
        call->resolve = JS_UNDEFINED;
        call->reject = JS_UNDEFINED;
        call->has_resolvers = false;
    }
    free(call->args);
    call->args = NULL;
}

/// Owner thread: consumes accepted replies. A typed transient failure on attempt 1 is requeued
/// once while the attempt budget allows and the run is not stopping.
static void process_replies(rpcm_host *h) {
    for (uint32_t i = 0; i < h->ncalls; i++) {
        call_t *call = &h->calls[i];
        pthread_mutex_lock(&h->mu);
        if (!call->reply_ready) {
            pthread_mutex_unlock(&h->mu);
            continue;
        }
        call->reply_ready = false;
        rpcm_disposition disposition = call->disposition;
        char *payload = call->payload;
        size_t payload_len = call->payload_len;
        call->payload = NULL;
        call->payload_len = 0;
        char code[RPCM_FAILURE_CODE_BYTES];
        memcpy(code, call->code, sizeof code);
        uint32_t attempts = call->attempt;
        bool retry = disposition == RPCM_REPLY_RETRYABLE_FAILURE && call->attempt == 1 &&
                     h->ncalls + h->retries < h->limits.max_attempts && h->phase != PHASE_TEARDOWN &&
                     h->stop_reason == RPCM_REASON_NONE && !atomic_load(&h->cancel_requested);
        if (retry) {
            call->state = CALL_QUEUED;
            call->attempt = 2;
        } else {
            call->state = CALL_DONE;
        }
        pthread_mutex_unlock(&h->mu);
        h->in_flight--;
        if (retry) {
            h->retries++;
        } else {
            complete_call(h, i, disposition == RPCM_REPLY_SUCCESS, payload, payload_len, code, attempts);
        }
        free(payload);
        publish_progress(h);
    }
}

// MARK: - Script errors

static void capture_script_error(rpcm_host *h, JSValue error) {
    JSContext *ctx = h->ctx;
    if (h->stop_reason == RPCM_REASON_NONE) {
        if (JS_IsNull(error) || JS_IsUninitialized(error)) {
            // QuickJS could not even allocate the error object.
            h->stop_reason = RPCM_REASON_MEMORY;
        } else {
            bool entered = guest_enter(h);
            size_t n = 0;
            const char *text = JS_ToCStringLen(ctx, &n, error);
            guest_leave(h, entered);
            if (text) {
                set_message(h, text, n);
                JS_FreeCString(ctx, text);
            } else {
                JSValue nested = JS_GetException(ctx);
                JS_FreeValue(ctx, nested);
                set_message(h, "<unprintable error>", strlen("<unprintable error>"));
            }
            if (h->stop_reason == RPCM_REASON_NONE) {
                if (!strcmp(h->message, "InternalError: out of memory")) {
                    h->stop_reason = RPCM_REASON_MEMORY;
                } else if (!strcmp(h->message, "RangeError: Maximum call stack size exceeded")) {
                    h->stop_reason = RPCM_REASON_STACK;
                } else if (h->script_reason == RPCM_REASON_NONE) {
                    h->script_reason = RPCM_REASON_SCRIPT_EXCEPTION;
                }
            }
        }
    }
    JS_FreeValue(ctx, error);
}

static void capture_pending_exception(rpcm_host *h) {
    capture_script_error(h, JS_GetException(h->ctx));
}

// MARK: - Owner thread

static JSContext *make_context(rpcm_host *h, JSRuntime *rt) {
    JSContext *ctx = JS_NewContextRaw(rt);
    if (!ctx) return NULL;
    JS_SetContextOpaque(ctx, h);
    // No WeakRef/FinalizationRegistry, module loader, std/os, timers or Intl.
    if (JS_AddIntrinsicBaseObjects(ctx) || JS_AddIntrinsicDate(ctx) || JS_AddIntrinsicEval(ctx)) goto fail;
    JS_AddIntrinsicRegExpCompiler(ctx);
    if (JS_AddIntrinsicRegExp(ctx) || JS_AddIntrinsicJSON(ctx) || JS_AddIntrinsicProxy(ctx) ||
        JS_AddIntrinsicMapSet(ctx) || JS_AddIntrinsicTypedArrays(ctx) || JS_AddIntrinsicPromise(ctx)) {
        goto fail;
    }

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue tools = JS_NewObject(ctx);
    if (JS_IsException(tools)) {
        JS_FreeValue(ctx, global);
        goto fail;
    }
    for (int i = 0; i < 4; i++) {
        JSValue fn = JS_NewCFunctionMagic(ctx, js_tool, kToolNames[i], 2, JS_CFUNC_generic_magic, i);
        if (JS_DefinePropertyValueStr(ctx, tools, kToolNames[i], fn, JS_PROP_ENUMERABLE) < 0) {
            JS_FreeValue(ctx, tools);
            JS_FreeValue(ctx, global);
            goto fail;
        }
    }
    if (JS_FreezeObject(ctx, tools) < 0) {
        JS_FreeValue(ctx, tools);
        JS_FreeValue(ctx, global);
        goto fail;
    }
    JSValue console = JS_NewObject(ctx);
    if (JS_IsException(console) ||
        JS_DefinePropertyValueStr(ctx, console, "log", JS_NewCFunction(ctx, js_console_log, "log", 1),
                                  JS_PROP_ENUMERABLE) < 0 ||
        JS_FreezeObject(ctx, console) < 0) {
        JS_FreeValue(ctx, console);
        JS_FreeValue(ctx, tools);
        JS_FreeValue(ctx, global);
        goto fail;
    }
    // Non-writable, non-configurable globals; the values are moved into the global object.
    int rc = 0;
    rc |= JS_DefinePropertyValueStr(ctx, global, "tools", tools, JS_PROP_ENUMERABLE) < 0;
    rc |= JS_DefinePropertyValueStr(ctx, global, "console", console, JS_PROP_ENUMERABLE) < 0;
    rc |= JS_DefinePropertyValueStr(ctx, global, "text", JS_NewCFunction(ctx, js_text, "text", 1),
                                    JS_PROP_ENUMERABLE) < 0;
    JS_FreeValue(ctx, global);
    if (rc) goto fail;
    return ctx;

fail:
    {
        JSValue exception = JS_GetException(ctx);
        JS_FreeValue(ctx, exception);
    }
    JS_FreeContext(ctx);
    return NULL;
}

static uint32_t count_state(const rpcm_host *h, call_state state) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < h->ncalls; i++) {
        if (h->calls[i].state == state) n++;
    }
    return n;
}

static bool any_reply_ready_locked(const rpcm_host *h) {
    for (uint32_t i = 0; i < h->ncalls; i++) {
        if (h->calls[i].reply_ready) return true;
    }
    return false;
}

/// Waits for a reply, a stop request, or the wall deadline.
static void wait_for_event(rpcm_host *h) {
    pthread_mutex_lock(&h->mu);
    if (!any_reply_ready_locked(h) && !atomic_load(&h->cancel_requested)) {
        double remaining = h->deadline_ms - mono_ms();
        if (remaining > 0) {
            if (remaining > 1000) remaining = 1000;
            struct timespec relative;
            relative.tv_sec = (time_t)(remaining / 1000);
            relative.tv_nsec = (long)((remaining - (double)relative.tv_sec * 1000) * 1e6);
            pthread_cond_timedwait_relative_np(&h->cv, &h->mu, &relative);
        }
    }
    pthread_mutex_unlock(&h->mu);
}

/// Formats the script's fulfilled return value as the last output entry.
static void commit_return_value(rpcm_host *h, JSValueConst value) {
    if (JS_IsUndefined(value)) return;
    size_t entry_len = 0;
    bool entered = guest_enter(h);
    int rc = entry_add_value(h, h->ctx, value, &entry_len, "return value");
    guest_leave(h, entered);
    if (rc == -1) {
        capture_pending_exception(h);
    } else if (rc == -2 || !entry_commit(h, entry_len)) {
        stop_for_output(h);
    }
}

static void run_loop(rpcm_host *h, JSValueConst promise) {
    JSRuntime *rt = h->rt;
    JSContext *ctx = h->ctx;
    for (;;) {
        if (h->phase == PHASE_RUNNING) {
            while (h->stop_reason == RPCM_REASON_NONE && JS_IsJobPending(rt) &&
                   JS_PromiseState(ctx, promise) == JS_PROMISE_PENDING) {
                JSContext *job_ctx = NULL;
                bool entered = guest_enter(h);
                int rc = JS_ExecutePendingJob(rt, &job_ctx);
                guest_leave(h, entered);
                if (rc < 0) {
                    capture_pending_exception(h);
                    return;
                }
                if (check_stop(h)) return;
                dispatch_ready(h);
            }
            if (h->stop_reason != RPCM_REASON_NONE) return;
            JSPromiseStateEnum state = JS_PromiseState(ctx, promise);
            if (state == JS_PROMISE_FULFILLED) {
                // Stop running guest jobs; drain admitted children for accounting only.
                JSValue value = JS_PromiseResult(ctx, promise);
                commit_return_value(h, value);
                JS_FreeValue(ctx, value);
                if (h->stop_reason != RPCM_REASON_NONE) return;
                h->phase = PHASE_DRAINING;
            } else if (state == JS_PROMISE_REJECTED) {
                capture_script_error(h, JS_PromiseResult(ctx, promise));
                if (h->stop_reason != RPCM_REASON_NONE) return;
                h->phase = PHASE_DRAINING;
            }
        }
        if (check_stop(h)) return;
        dispatch_ready(h);
        uint32_t queued = count_state(h, CALL_QUEUED);
        if (queued == 0 && h->in_flight == 0) {
            if (h->phase == PHASE_DRAINING) return;
            if (!JS_IsJobPending(rt)) {
                h->script_reason = RPCM_REASON_UNSETTLEABLE_PROMISE;
                set_message(h, reason_text(RPCM_REASON_UNSETTLEABLE_PROMISE),
                            strlen(reason_text(RPCM_REASON_UNSETTLEABLE_PROMISE)));
                return;
            }
            continue;
        }
        wait_for_event(h);
        process_replies(h);
    }
}

static void build_outcome(rpcm_host *h) {
    rpcm_outcome *o = &h->outcome;
    rpcm_reason reason = h->stop_reason != RPCM_REASON_NONE ? h->stop_reason : h->script_reason;
    o->reason = reason;
    switch (reason) {
    case RPCM_REASON_NONE: o->status = RPCM_STATUS_SUCCESS; break;
    case RPCM_REASON_SCRIPT_EXCEPTION:
    case RPCM_REASON_UNSETTLEABLE_PROMISE: o->status = RPCM_STATUS_SCRIPT_ERROR; break;
    case RPCM_REASON_WALL_TIME: o->status = RPCM_STATUS_TIMEOUT; break;
    case RPCM_REASON_CANCELLED: o->status = RPCM_STATUS_CANCELLED; break;
    case RPCM_REASON_CPU_TIME:
    case RPCM_REASON_MEMORY:
    case RPCM_REASON_STACK:
    case RPCM_REASON_OUTPUT:
    case RPCM_REASON_CALLS: o->status = RPCM_STATUS_LIMIT_EXCEEDED; break;
    case RPCM_REASON_HOST_ALLOCATION:
    case RPCM_REASON_ENGINE_INIT: o->status = RPCM_STATUS_RUNTIME_ERROR; break;
    }
    o->output = h->output;
    o->output_len = h->output_len;
    h->output[h->output_len] = '\0';
    o->message = h->message;
    o->message_len = h->message_len;
    o->calls = h->ncalls;
    o->attempts = h->attempts_dispatched;
    o->completed = h->completed;
    o->failed = h->failed;
    o->queued_at_stop = count_state(h, CALL_QUEUED);
    o->in_flight_at_stop = count_state(h, CALL_IN_FLIGHT);
    o->retries = h->retries;
    o->max_in_flight_observed = h->max_in_flight_seen;
    o->guest_cpu_ms = h->cpu_acc_ms;
    o->wall_ms = mono_ms() - h->t0_ms;
    publish_progress(h);
}

static void run_script(rpcm_host *h) {
    h->t0_ms = mono_ms();
    h->deadline_ms = h->t0_ms + (double)h->limits.wall_ms;
    h->rt = JS_NewRuntime();
    if (!h->rt) {
        h->stop_reason = RPCM_REASON_ENGINE_INIT;
        goto finish;
    }
    JS_SetMemoryLimit(h->rt, h->limits.heap_bytes);
    JS_SetMaxStackSize(h->rt, h->limits.stack_bytes);
    JS_SetInterruptHandler(h->rt, interrupt_handler, h);
    JS_SetCanBlock(h->rt, false);
    h->ctx = make_context(h, h->rt);
    if (!h->ctx) {
        h->stop_reason = RPCM_REASON_ENGINE_INIT;
        JS_FreeRuntime(h->rt);
        h->rt = NULL;
        goto finish;
    }

    JSContext *ctx = h->ctx;
    JSValue promise = JS_UNDEFINED;
    bool entered = guest_enter(h);
    JSValue fn = JS_Eval(ctx, h->source, h->source_len, "<code_mode>", JS_EVAL_TYPE_GLOBAL);
    guest_leave(h, entered);
    if (JS_IsException(fn)) {
        capture_pending_exception(h);
    } else {
        entered = guest_enter(h);
        promise = JS_Call(ctx, fn, JS_UNDEFINED, 0, NULL);
        guest_leave(h, entered);
        JS_FreeValue(ctx, fn);
        if (JS_IsException(promise)) {
            promise = JS_UNDEFINED;
            capture_pending_exception(h);
        } else if (!JS_IsPromise(promise)) {
            h->script_reason = RPCM_REASON_SCRIPT_EXCEPTION;
            set_message(h, "the script must be an async function body", strlen("the script must be an async function body"));
        } else {
            check_stop(h);
            if (h->stop_reason == RPCM_REASON_NONE) {
                dispatch_ready(h);
                run_loop(h, promise);
            }
        }
    }

    // Teardown on the owner thread: stop accepting replies, account for the ones already
    // accepted without running guest code, free every value, then the context and runtime.
    pthread_mutex_lock(&h->mu);
    h->accepting = false;
    pthread_mutex_unlock(&h->mu);
    h->phase = PHASE_TEARDOWN;
    process_replies(h);
    for (uint32_t i = 0; i < h->ncalls; i++) {
        call_t *call = &h->calls[i];
        if (call->has_resolvers) {
            JS_FreeValue(ctx, call->resolve);
            JS_FreeValue(ctx, call->reject);
            call->has_resolvers = false;
        }
        free(call->args);
        call->args = NULL;
    }
    JS_FreeValue(ctx, promise);
    {
        JSValue exception = JS_GetException(ctx);
        JS_FreeValue(ctx, exception);
    }
    JS_FreeContext(ctx);
    JS_FreeRuntime(h->rt);
    h->ctx = NULL;
    h->rt = NULL;

finish:
    pthread_mutex_lock(&h->mu);
    h->accepting = false;
    pthread_mutex_unlock(&h->mu);
    build_outcome(h);
}

static void *owner_main(void *arg) {
    rpcm_host *h = arg;
    pthread_setname_np("RepoPrompt code_mode");
    run_script(h);
    rpcm_exit_fn on_exit = h->on_exit;
    void *context = h->context;
    // The host must not be touched after this call: the exit handler may join and destroy it.
    if (on_exit) on_exit(context);
    return NULL;
}

// MARK: - Public API

static bool limits_are_valid(const rpcm_limits *l) {
    rpcm_limits p = rpcm_production_limits();
    return l->wall_ms > 0 && l->wall_ms <= p.wall_ms && l->cpu_ms > 0 && l->cpu_ms <= p.cpu_ms &&
           l->heap_bytes > 0 && l->heap_bytes <= p.heap_bytes && l->stack_bytes > 0 &&
           l->stack_bytes <= p.stack_bytes && l->script_bytes > 0 && l->script_bytes <= p.script_bytes &&
           l->args_bytes > 0 && l->args_bytes <= p.args_bytes && l->result_bytes > 0 &&
           l->result_bytes <= p.result_bytes && l->output_bytes > 0 && l->output_bytes <= p.output_bytes &&
           l->max_attempts > 0 && l->max_attempts <= p.max_attempts && l->max_in_flight > 0 &&
           l->max_in_flight <= p.max_in_flight;
}

rpcm_create_status rpcm_host_create(const char *script, size_t script_len, const rpcm_limits *limits,
                                    rpcm_host **out_host) {
    if (!out_host) return RPCM_CREATE_INVALID_LIMITS;
    *out_host = NULL;
    if (!limits || !limits_are_valid(limits)) return RPCM_CREATE_INVALID_LIMITS;
    if (script_len > limits->script_bytes) return RPCM_CREATE_SCRIPT_TOO_LARGE;
    if (script_len > 0 && !script) return RPCM_CREATE_SCRIPT_NOT_UTF8;
    if (script_len > 0 && !utf8_is_valid(script, script_len)) return RPCM_CREATE_SCRIPT_NOT_UTF8;

    rpcm_host *h = calloc(1, sizeof *h);
    if (!h) return RPCM_CREATE_ALLOCATION_FAILED;
    h->limits = *limits;
    size_t prefix = sizeof kSourcePrefix - 1;
    size_t suffix = sizeof kSourceSuffix - 1;
    h->source_len = prefix + script_len + suffix;
    h->source = malloc(h->source_len + 1);
    h->output = malloc((size_t)limits->output_bytes + 1);
    h->scratch = malloc(limits->output_bytes);
    if (!h->source || !h->output || !h->scratch) goto allocation_failed;
    if (pthread_mutex_init(&h->mu, NULL) != 0) goto allocation_failed;
    if (pthread_cond_init(&h->cv, NULL) != 0) {
        pthread_mutex_destroy(&h->mu);
        goto allocation_failed;
    }
    memcpy(h->source, kSourcePrefix, prefix);
    if (script_len > 0) memcpy(h->source + prefix, script, script_len);
    memcpy(h->source + prefix + script_len, kSourceSuffix, suffix);
    h->source[h->source_len] = '\0';
    h->output[0] = '\0';
    atomic_init(&h->cancel_requested, false);
    h->accepting = true;
    h->phase = PHASE_RUNNING;
    *out_host = h;
    return RPCM_CREATE_OK;

allocation_failed:
    free(h->source);
    free(h->output);
    free(h->scratch);
    free(h);
    return RPCM_CREATE_ALLOCATION_FAILED;
}

int rpcm_host_start(rpcm_host *h, rpcm_dispatch_fn dispatch, rpcm_exit_fn on_exit, void *context) {
    if (!h || !dispatch) return EINVAL;
    if (h->started) return EALREADY;
    h->dispatch = dispatch;
    h->on_exit = on_exit;
    h->context = context;
    pthread_attr_t attributes;
    int rc = pthread_attr_init(&attributes);
    if (rc != 0) return rc;
    rc = pthread_attr_setstacksize(&attributes, kOwnerThreadStackBytes);
    if (rc == 0) rc = pthread_create(&h->thread, &attributes, owner_main, h);
    pthread_attr_destroy(&attributes);
    if (rc == 0) h->started = true;
    return rc;
}

rpcm_submit_status rpcm_host_submit_reply(rpcm_host *h, uint32_t call_id, uint32_t attempt,
                                          rpcm_disposition disposition, const char *payload_json,
                                          size_t payload_len, const char *failure_code) {
    if (!h || disposition > RPCM_REPLY_RETRYABLE_FAILURE || (payload_len > 0 && !payload_json)) {
        return RPCM_SUBMIT_INVALID;
    }
    bool too_large = payload_len > h->limits.result_bytes;
    char *copy = NULL;
    if (!too_large && payload_json) {
        copy = malloc(payload_len + 1);
        if (copy) {
            memcpy(copy, payload_json, payload_len);
            copy[payload_len] = '\0';
        }
    }
    pthread_mutex_lock(&h->mu);
    call_t *call = (call_id >= 1 && call_id <= h->ncalls) ? &h->calls[call_id - 1] : NULL;
    if (!h->accepting || !call || call->state != CALL_IN_FLIGHT || call->attempt != attempt || call->reply_ready) {
        pthread_mutex_unlock(&h->mu);
        free(copy);
        return RPCM_SUBMIT_NOT_ACCEPTED;
    }
    call->reply_ready = true;
    if (too_large) {
        call->disposition = RPCM_REPLY_FAILURE;
        call->payload = NULL;
        call->payload_len = 0;
        copy_code(call->code, "child_result_too_large");
    } else if (payload_json && !copy) {
        call->disposition = RPCM_REPLY_FAILURE;
        call->payload = NULL;
        call->payload_len = 0;
        copy_code(call->code, "host_allocation_failure");
    } else {
        call->disposition = disposition;
        call->payload = copy;
        call->payload_len = copy ? payload_len : 0;
        copy_code(call->code, failure_code);
    }
    pthread_cond_signal(&h->cv);
    pthread_mutex_unlock(&h->mu);
    return RPCM_SUBMIT_ACCEPTED;
}

void rpcm_host_request_stop(rpcm_host *h) {
    if (!h) return;
    atomic_store(&h->cancel_requested, true);
    pthread_mutex_lock(&h->mu);
    h->accepting = false;
    pthread_cond_signal(&h->cv);
    pthread_mutex_unlock(&h->mu);
}

const rpcm_outcome *rpcm_host_join(rpcm_host *h) {
    if (!h || !h->started) return NULL;
    if (!h->joined) {
        pthread_join(h->thread, NULL);
        h->joined = true;
    }
    return &h->outcome;
}

size_t rpcm_host_snapshot(rpcm_host *h, rpcm_progress *progress, char *output, size_t output_capacity) {
    if (!h || !progress) return 0;
    pthread_mutex_lock(&h->mu);
    *progress = h->progress;
    size_t n = progress->output_len < output_capacity ? progress->output_len : output_capacity;
    if (output && n > 0) memcpy(output, h->output, n);
    pthread_mutex_unlock(&h->mu);
    return output ? n : 0;
}

bool rpcm_host_destroy(rpcm_host *h) {
    if (!h) return true;
    if (h->started && !h->joined) return false;
    for (uint32_t i = 0; i < RPCM_MAX_ATTEMPTS; i++) {
        free(h->calls[i].payload);
        free(h->calls[i].args);
    }
    pthread_cond_destroy(&h->cv);
    pthread_mutex_destroy(&h->mu);
    free(h->source);
    free(h->output);
    free(h->scratch);
    free(h);
    return true;
}
