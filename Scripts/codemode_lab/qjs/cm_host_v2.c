// cm_host_v2: v2 executor variant of cm_host (lab Phase 3). Differences from v1:
//   tools.X(args, {allowError}) ; a reply whose result.isError (or a bridge "error") REJECTS the promise with
//   Error(result.error) unless allowError, in which case it resolves {..., isError:true, error}. Stats add completed/queued/inflight_at_stop.
// cm_host: QuickJS-ng code_mode runner (NO quickjs-libc). Stdio protocol spoken by ../rp_proxy.py (run_codemode):
//   in : {"type":"start","script":...}  {"type":"reply","id":N,"result":{...}|"error":"..."}  {"type":"cancel"}
//   out: {"type":"call","id":N,"name":...,"args":{...}}  {"type":"done","output":...,"error"?:...,"stats":{...}}
// Limits (env overridable): CM_WALL_MS=60000 CM_CPU_MS=2000 CM_HEAP_MB=64 CM_STACK_KB=1024 CM_MAX_CALLS=32
//   CM_MAX_INFLIGHT=4 CM_CHILD_MAX=2097152 (chars of result.text) CM_OUT_MAX=32768 (bytes)
//   CM_OUT_MODE=fail|truncate (fail = plan semantics; truncate = keep up to 1 MiB, bridge truncates like rp_proxy)
//   CM_CALL_MODE=fail|reject (fail = plan: call #33 aborts the run; reject = rp_proxy parity: call rejects, script continues)
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#include <malloc/malloc.h>
#include "quickjs.h"

enum { AB_NONE, AB_CPU, AB_WALL, AB_CANCEL, AB_CALLS, AB_OUTPUT, AB_CHILD, AB_DEADLOCK, AB_PROTOCOL, AB_MEMORY };
static const char *ab_text[] = {"", "CPU time limit exceeded", "wall time limit exceeded", "cancelled",
    "nested tool call limit exceeded", "output limit exceeded", "tool result too large", "script is awaiting a promise that can never settle",
    "protocol error", "memory limit exceeded"};

typedef struct Msg { struct Msg *next; char *line; size_t len; } Msg;
static pthread_mutex_t q_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_cv = PTHREAD_COND_INITIALIZER;
static Msg *q_head, *q_tail; static int q_eof;
static atomic_int g_cancel;

static void *reader(void *unused) {
    (void)unused; char *line = NULL; size_t cap = 0; ssize_t n;
    while ((n = getline(&line, &cap, stdin)) > 0) {
        Msg *m = calloc(1, sizeof *m); m->line = malloc(n + 1); memcpy(m->line, line, n + 1); m->len = n;
        if (strstr(m->line, "\"type\":\"cancel\"")) atomic_store(&g_cancel, 1);
        pthread_mutex_lock(&q_mu); if (q_tail) q_tail->next = m; else q_head = m; q_tail = m;
        pthread_cond_signal(&q_cv); pthread_mutex_unlock(&q_mu);
    }
    pthread_mutex_lock(&q_mu); q_eof = 1; atomic_store(&g_cancel, 1); pthread_cond_signal(&q_cv); pthread_mutex_unlock(&q_mu);
    free(line); return NULL;
}

static long envl(const char *k, long d) { const char *v = getenv(k); return v && *v ? atol(v) : d; }
static long W_MS, CPU_MS, HEAP_MB, STACK_KB, MAX_CALLS, MAX_INFLIGHT, CHILD_MAX, OUT_MAX; static int OUT_FAIL, CALL_FAIL;

typedef struct Call { long id; int tool; char *args; JSValue res, rej; int state; /*0 queued 1 sent 2 done*/ int allow_error; } Call;
typedef struct {
    JSRuntime *rt; JSContext *ctx;
    int abort; double t0_wall, deadline;
    double cpu_acc, cpu_enter; int in_js;
    Call *calls; long ncalls, cap_calls, inflight, max_inflight_seen, rejected_calls;
    char *out; size_t out_len, out_cap; int out_entries; int out_trunc; long failed_children;
    size_t mem_cur, mem_peak; long child_chars;
} Host;
static Host H;
static const char *TOOLS[] = {"read_file", "file_search", "get_code_structure", "get_file_tree"};

static double now_wall(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static double now_cpu(void) { struct timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static void js_enter(void) { H.cpu_enter = now_cpu(); H.in_js = 1; }
static void js_leave(void) { if (H.in_js) H.cpu_acc += now_cpu() - H.cpu_enter; H.in_js = 0; }
static double cpu_used(void) { return H.cpu_acc + (H.in_js ? now_cpu() - H.cpu_enter : 0); }

static int interrupt_cb(JSRuntime *rt, void *op) {
    (void)rt; (void)op;
    if (H.abort) return 1;
    if (atomic_load(&g_cancel)) { H.abort = AB_CANCEL; return 1; }
    if (now_wall() > H.deadline) { H.abort = AB_WALL; return 1; }
    if (cpu_used() > CPU_MS) { H.abort = AB_CPU; return 1; }
    return 0;
}

// tracking allocator (peak accounting only; the limit is JS_SetMemoryLimit's)
static void track(long d) { H.mem_cur += d; if (H.mem_cur > H.mem_peak) H.mem_peak = H.mem_cur; }
static void *a_calloc(void *o, size_t c, size_t s) { (void)o; void *p = calloc(c, s); if (p) track(malloc_size(p)); return p; }
static void *a_malloc(void *o, size_t s) { (void)o; void *p = malloc(s); if (p) track(malloc_size(p)); return p; }
static void a_free(void *o, void *p) { (void)o; if (p) { H.mem_cur -= malloc_size(p); free(p); } }
static void *a_realloc(void *o, void *p, size_t s) { (void)o; size_t old = p ? malloc_size(p) : 0;
    if (p && s == 0) { H.mem_cur -= old; free(p); return NULL; }
    void *q = realloc(p, s); if (q) track((long)malloc_size(q) - (long)old); return q; }
static size_t a_usable(const void *p) { return malloc_size(p); }
static const JSMallocFunctions MF = {a_calloc, a_malloc, a_free, a_realloc, a_usable};

typedef struct { char *b; size_t n, cap; } Buf;
static void bput(Buf *b, const char *s, size_t n) { if (!b->b || b->n + n + 1 > b->cap) { b->cap = (b->n + n + 1) * 2; b->b = realloc(b->b, b->cap); } memcpy(b->b + b->n, s, n); b->n += n; b->b[b->n] = 0; }
static void bputs(Buf *b, const char *s) { bput(b, s, strlen(s)); }
static int utf8_len(const unsigned char *s, size_t n) {
    unsigned c = s[0]; int l; unsigned min;
    if (c < 0x80) return 1; else if ((c & 0xE0) == 0xC0) { l = 2; min = 0x80; } else if ((c & 0xF0) == 0xE0) { l = 3; min = 0x800; } else if ((c & 0xF8) == 0xF0) { l = 4; min = 0x10000; } else return -1;
    if ((size_t)l > n) return -1; unsigned cp = c & (0x7F >> l);
    for (int i = 1; i < l; i++) { if ((s[i] & 0xC0) != 0x80) return -1; cp = (cp << 6) | (s[i] & 0x3F); }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return -1; return l;
}
// JSON string escaping; validates UTF-8 (lone surrogates / invalid bytes -> U+FFFD) so the bridge never sees invalid UTF-8
static void bjson_str(Buf *b, const char *s, size_t n) {
    bput(b, "\"", 1); const unsigned char *u = (const unsigned char *)s; char tmp[8];
    for (size_t i = 0; i < n;) {
        unsigned c = u[i];
        if (c == '"' || c == '\\') { tmp[0] = '\\'; tmp[1] = c; bput(b, tmp, 2); i++; }
        else if (c < 0x20) { snprintf(tmp, sizeof tmp, "\\u%04x", c); bput(b, tmp, 6); i++; }
        else if (c < 0x80) { bput(b, (const char *)u + i, 1); i++; }
        else { int l = utf8_len(u + i, n - i); if (l < 0) { bputs(b, "\\ufffd"); i += (c >= 0xE0 && c < 0xF0 && n - i >= 3) ? 3 : 1; } else { bput(b, (const char *)u + i, l); i += l; } }
    }
    bput(b, "\"", 1);
}
static pthread_mutex_t out_mu = PTHREAD_MUTEX_INITIALIZER;
static void emit(Buf *b) { pthread_mutex_lock(&out_mu); fwrite(b->b, 1, b->n, stdout); fputc('\n', stdout); fflush(stdout); pthread_mutex_unlock(&out_mu); }

static void out_append(const char *s, size_t n) {
    size_t hard = OUT_FAIL ? (size_t)OUT_MAX : (size_t)(1 << 20);
    size_t sep = H.out_entries ? 1 : 0, take = n;
    if (H.out_len + sep + n > hard) {
        if (OUT_FAIL) { H.abort = AB_OUTPUT; return; }
        H.out_trunc = 1; if (H.out_len + sep >= hard) return; take = hard - H.out_len - sep;
    }
    if (!H.out || H.out_len + sep + take + 1 > H.out_cap) { H.out_cap = (H.out_len + sep + take + 1) * 2; H.out = realloc(H.out, H.out_cap); }
    if (sep) H.out[H.out_len++] = '\n';
    memcpy(H.out + H.out_len, s, take); H.out_len += take; H.out_entries++;
}
// fmt(v): string as-is, else JSON.stringify(v, null, 1); undefined -> "" (as Array.join does in cm_runner.js)
static int fmt_append(JSContext *ctx, Buf *dst, JSValueConst v) {
    JSValue s;
    if (JS_IsString(v)) s = JS_DupValue(ctx, v);
    else { JSValue sp = JS_NewInt32(ctx, 1); s = JS_JSONStringify(ctx, v, JS_UNDEFINED, sp); if (JS_IsException(s)) return -1; }
    if (JS_IsUndefined(s)) return 0;
    size_t n; const char *c = JS_ToCStringLen(ctx, &n, s); JS_FreeValue(ctx, s); if (!c) return -1;
    bput(dst, c, n); JS_FreeCString(ctx, c); return 0;
}
static JSValue throw_abort(JSContext *ctx) {
    JSValue e = JS_NewError(ctx);
    JS_DefinePropertyValueStr(ctx, e, "message", JS_NewString(ctx, ab_text[H.abort]), JS_PROP_C_W_E);
    JS_SetUncatchableError(ctx, e); return JS_Throw(ctx, e);
}
static JSValue fn_text(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; if (H.abort) return throw_abort(ctx);
    Buf b = {0}; bputs(&b, "");
    if (fmt_append(ctx, &b, argc ? argv[0] : JS_UNDEFINED) < 0) { free(b.b); return JS_EXCEPTION; }
    out_append(b.b, b.n); free(b.b); if (H.abort) return throw_abort(ctx); return JS_UNDEFINED;
}
static JSValue fn_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; if (H.abort) return throw_abort(ctx);
    Buf b = {0}; bputs(&b, "");
    for (int i = 0; i < argc; i++) { if (i) bput(&b, " ", 1); if (fmt_append(ctx, &b, argv[i]) < 0) { free(b.b); return JS_EXCEPTION; } }
    out_append(b.b, b.n); free(b.b); if (H.abort) return throw_abort(ctx); return JS_UNDEFINED;
}

static void send_call(Call *c) {
    Buf b = {0}; char tmp[64]; snprintf(tmp, sizeof tmp, "{\"type\":\"call\",\"id\":%ld,\"name\":", c->id); bputs(&b, tmp);
    bjson_str(&b, TOOLS[c->tool], strlen(TOOLS[c->tool])); bputs(&b, ",\"args\":"); bputs(&b, c->args); bputs(&b, "}");
    emit(&b); free(b.b); c->state = 1; H.inflight++; if (H.inflight > H.max_inflight_seen) H.max_inflight_seen = H.inflight;
}
static void pump_calls(void) {
    for (long i = 0; i < H.ncalls && H.inflight < MAX_INFLIGHT; i++) if (H.calls[i].state == 0) send_call(&H.calls[i]);
}
static JSValue fn_tool(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data) {
    (void)this_val; (void)data; if (H.abort) return throw_abort(ctx);
    JSValueConst a = argc ? argv[0] : JS_UNDEFINED; char *args;
    if (!JS_ToBool(ctx, a)) args = strdup("{}");
    else {
        if (!JS_IsObject(a) || JS_IsArray(a) || JS_IsFunction(ctx, a)) return JS_ThrowTypeError(ctx, "tools.%s: arguments must be a plain object", TOOLS[magic]);
        JSValue s = JS_JSONStringify(ctx, a, JS_UNDEFINED, JS_UNDEFINED);   // getters/proxies/toJSON run as (interruptible) guest code; cycles throw
        if (JS_IsException(s)) return JS_EXCEPTION;
        if (H.abort) { JS_FreeValue(ctx, s); return throw_abort(ctx); }
        size_t n; const char *c = JS_IsString(s) ? JS_ToCStringLen(ctx, &n, s) : NULL; JS_FreeValue(ctx, s);
        if (!c) return JS_ThrowTypeError(ctx, "tools.%s: arguments are not JSON-serializable", TOOLS[magic]);
        if (c[0] != '{' || n > 65536) { JS_FreeCString(ctx, c); return JS_ThrowTypeError(ctx, "tools.%s: arguments must serialize to a JSON object <= 64 KiB", TOOLS[magic]); }
        Buf v = {0}; bput(&v, c, n); JS_FreeCString(ctx, c); args = v.b;
    }
    int allow_error = 0;
    if (argc > 1 && JS_IsObject(argv[1])) {
        JSValue ae = JS_GetPropertyStr(ctx, argv[1], "allowError");
        if (JS_IsException(ae)) { free(args); return JS_EXCEPTION; }
        allow_error = JS_ToBool(ctx, ae); JS_FreeValue(ctx, ae);
        if (H.abort) { free(args); return throw_abort(ctx); }
    }
    if (H.ncalls + H.rejected_calls >= MAX_CALLS) {
        free(args);
        if (CALL_FAIL) { H.abort = AB_CALLS; return throw_abort(ctx); }
        H.rejected_calls++;
        JSValue err = JS_NewError(ctx); JS_DefinePropertyValueStr(ctx, err, "message", JS_NewString(ctx, "call limit exceeded"), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        JSValue rp = JS_NewSettledPromise(ctx, true, err); JS_FreeValue(ctx, err); return rp;
    }
    if (H.ncalls == H.cap_calls) { H.cap_calls = H.cap_calls ? H.cap_calls * 2 : 16; H.calls = realloc(H.calls, H.cap_calls * sizeof(Call)); }
    JSValue rf[2]; JSValue p = JS_NewPromiseCapability(ctx, rf); if (JS_IsException(p)) { free(args); return p; }
    Call *c = &H.calls[H.ncalls]; c->id = H.ncalls + 1; c->tool = magic; c->args = args; c->res = rf[0]; c->rej = rf[1]; c->state = 0; c->allow_error = allow_error; H.ncalls++;
    pump_calls();
    return p;
}

static JSContext *make_ctx(JSRuntime *rt) {
    JSContext *ctx = JS_NewContextRaw(rt);
    JS_AddIntrinsicBaseObjects(ctx); JS_AddIntrinsicDate(ctx); JS_AddIntrinsicEval(ctx); JS_AddIntrinsicRegExpCompiler(ctx);
    JS_AddIntrinsicRegExp(ctx); JS_AddIntrinsicJSON(ctx); JS_AddIntrinsicProxy(ctx); JS_AddIntrinsicMapSet(ctx);
    JS_AddIntrinsicTypedArrays(ctx); JS_AddIntrinsicPromise(ctx); JS_AddIntrinsicBigInt(ctx); JS_AddIntrinsicWeakRef(ctx);
    JSValue g = JS_GetGlobalObject(ctx);
    JSValue tools = JS_NewObject(ctx);
    for (int i = 0; i < 4; i++) JS_DefinePropertyValueStr(ctx, tools, TOOLS[i], JS_NewCFunctionData2(ctx, fn_tool, TOOLS[i], 2, i, 0, NULL), JS_PROP_ENUMERABLE);
    JS_FreezeObject(ctx, tools);
    JS_DefinePropertyValueStr(ctx, g, "tools", tools, JS_PROP_ENUMERABLE);   // non-writable, non-configurable
    JS_DefinePropertyValueStr(ctx, g, "text", JS_NewCFunction(ctx, fn_text, "text", 1), JS_PROP_ENUMERABLE);
    JSValue con = JS_NewObject(ctx); JS_SetPropertyStr(ctx, con, "log", JS_NewCFunction(ctx, fn_log, "log", 1));
    JS_FreezeObject(ctx, con);
    JS_DefinePropertyValueStr(ctx, g, "console", con, JS_PROP_ENUMERABLE);
    JS_FreeValue(ctx, g);
    return ctx;
}

static Msg *pop_msg(double until_ms) {
    pthread_mutex_lock(&q_mu);
    if (!q_head && !q_eof) {
        double rem = until_ms - now_wall();
        if (rem > 0) {
            struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
            long ns = ts.tv_nsec + (long)(rem > 200 ? 200 : rem) * 1000000L; ts.tv_sec += ns / 1000000000L; ts.tv_nsec = ns % 1000000000L;
            pthread_cond_timedwait(&q_cv, &q_mu, &ts);
        }
    }
    Msg *m = q_head; if (m) { q_head = m->next; if (!q_head) q_tail = NULL; }
    pthread_mutex_unlock(&q_mu); return m;
}
static JSValue getp(JSContext *ctx, JSValueConst o, const char *k) { return JS_IsObject(o) ? JS_GetPropertyStr(ctx, o, k) : JS_UNDEFINED; }

// error text like cm_runner.js: String(e && e.stack ? e.message : e)
static char *err_text(JSContext *ctx, JSValue e) {
    if (H.abort) return strdup(ab_text[H.abort]);
    if (JS_IsNull(e) || JS_IsUninitialized(e)) { H.abort = AB_MEMORY; return strdup(ab_text[H.abort]); }  // OOM while building the error object
    js_enter();
    JSValue src = JS_DupValue(ctx, e);
    if (JS_IsObject(e)) { JSValue st = JS_GetPropertyStr(ctx, e, "stack"); int has = JS_ToBool(ctx, st) || JS_IsError(e); JS_FreeValue(ctx, st);
        if (has) { JS_FreeValue(ctx, src); src = JS_GetPropertyStr(ctx, e, "message"); } }
    const char *c = JS_ToCString(ctx, src); js_leave(); JS_FreeValue(ctx, src);
    if (H.abort) { if (c) JS_FreeCString(ctx, c); return strdup(ab_text[H.abort]); }
    if (c && !strcmp(c, "out of memory")) { JS_FreeCString(ctx, c); H.abort = AB_MEMORY; return strdup(ab_text[H.abort]); }
    char *r = strdup(c ? c : "<unprintable error>"); if (c) JS_FreeCString(ctx, c); else { JSValue x = JS_GetException(ctx); JS_FreeValue(ctx, x); }
    return r;
}

static long n_state(int st) { long k = 0; for (long i = 0; i < H.ncalls; i++) if (H.calls[i].state == st) k++; return k; }
static void finish(const char *error) {
    double wall = now_wall() - H.t0_wall; struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    Buf b = {0}; bputs(&b, "{\"type\":\"done\",\"output\":"); bjson_str(&b, H.out ? H.out : "", H.out_len);
    if (error) { bputs(&b, ",\"error\":"); bjson_str(&b, error, strlen(error)); }
    char tmp[900]; snprintf(tmp, sizeof tmp, ",\"stats\":{\"calls\":%ld,\"rejected_calls\":%ld,\"max_inflight\":%ld,\"cpu_ms\":%.1f,\"wall_ms\":%.1f,\"heap_peak\":%zu,\"rss_peak\":%ld,\"child_chars\":%ld,\"limit\":\"%s\",\"out_truncated\":%s,\"completed\":%ld,\"inflight_at_stop\":%ld,\"queued_at_stop\":%ld,\"failed_children\":%ld,\"out_bytes\":%zu}}",
        H.ncalls, H.rejected_calls, H.max_inflight_seen, cpu_used(), wall, H.mem_peak, (long)ru.ru_maxrss, H.child_chars, H.abort ? ab_text[H.abort] : "", H.out_trunc ? "true" : "false",
        n_state(2), n_state(1), n_state(0), H.failed_children, H.out_len);
    bputs(&b, tmp); emit(&b); free(b.b);
}

#define TAKE_EXC() do { JSValue e_ = JS_GetException(ctx); error = err_text(ctx, e_); JS_FreeValue(ctx, e_); } while (0)
static void *js_main(void *unused) {
    (void)unused;
    Msg *m = NULL; while (!m) { m = pop_msg(now_wall() + 1e9); if (!m && q_eof) return NULL; }
    H.t0_wall = now_wall(); H.deadline = H.t0_wall + W_MS;
    H.rt = JS_NewRuntime2(&MF, NULL);
    JS_SetMemoryLimit(H.rt, (size_t)HEAP_MB << 20); JS_SetMaxStackSize(H.rt, (size_t)STACK_KB << 10);
    JS_SetInterruptHandler(H.rt, interrupt_cb, NULL); JS_SetCanBlock(H.rt, false);
    H.ctx = make_ctx(H.rt); JSContext *ctx = H.ctx;
    JSValue sm = JS_ParseJSON(ctx, m->line, m->len, "<start>"); free(m->line); free(m);
    JSValue sv = getp(ctx, sm, "script"); size_t slen; const char *script = JS_IsString(sv) ? JS_ToCStringLen(ctx, &slen, sv) : NULL;
    JS_FreeValue(ctx, sv); JS_FreeValue(ctx, sm);
    if (!script) { H.abort = AB_PROTOCOL; finish("protocol error: missing script"); fflush(stdout); _exit(0); }
    Buf src = {0}; bputs(&src, "(async () => {\n"); bput(&src, script, slen); bputs(&src, "\n})"); JS_FreeCString(ctx, script);
    char *error = NULL; JSValue prom = JS_UNDEFINED;
    js_enter(); JSValue fn = JS_Eval(ctx, src.b, src.n, "<code_mode>", JS_EVAL_TYPE_GLOBAL); js_leave(); free(src.b);
    if (JS_IsException(fn)) { TAKE_EXC(); goto done; }
    js_enter(); prom = JS_Call(ctx, fn, JS_UNDEFINED, 0, NULL); js_leave(); JS_FreeValue(ctx, fn);
    if (JS_IsException(prom)) { TAKE_EXC(); goto done; }
    for (;;) {
        while (!H.abort && JS_IsJobPending(H.rt) && JS_PromiseState(ctx, prom) == JS_PROMISE_PENDING) {   // stop running guest jobs once settled
            JSContext *jc; js_enter(); int r = JS_ExecutePendingJob(H.rt, &jc); js_leave();
            if (r < 0) { TAKE_EXC(); goto done; }
        }
        if (H.abort) { error = strdup(ab_text[H.abort]); goto done; }
        if (atomic_load(&g_cancel)) { H.abort = AB_CANCEL; error = strdup(ab_text[H.abort]); goto done; }
        if (now_wall() > H.deadline) { H.abort = AB_WALL; error = strdup(ab_text[H.abort]); goto done; }
        int st = JS_PromiseState(ctx, prom);
        if (st == JS_PROMISE_FULFILLED) {
            JSValue r = JS_PromiseResult(ctx, prom);
            if (!JS_IsUndefined(r)) { Buf b = {0}; bputs(&b, ""); js_enter(); int rc = fmt_append(ctx, &b, r); js_leave();
                if (rc < 0) TAKE_EXC(); else out_append(b.b, b.n);
                free(b.b); if (H.abort && !error) error = strdup(ab_text[H.abort]); }
            JS_FreeValue(ctx, r); goto done;
        }
        if (st == JS_PROMISE_REJECTED) { JSValue e = JS_PromiseResult(ctx, prom); error = err_text(ctx, e); JS_FreeValue(ctx, e); goto done; }
        pump_calls();
        if (H.inflight == 0 && !JS_IsJobPending(H.rt)) { H.abort = AB_DEADLOCK; error = strdup(ab_text[H.abort]); goto done; }
        Msg *r = pop_msg(H.deadline); if (!r) continue;
        JSValue rv = JS_ParseJSON(ctx, r->line, r->len, "<reply>"); size_t rlen = r->len; free(r->line); free(r);
        if (JS_IsException(rv)) { JSValue e = JS_GetException(ctx); JS_FreeValue(ctx, e); H.abort = AB_PROTOCOL; error = strdup("protocol error: unparseable tool reply"); goto done; }
        JSValue ty = getp(ctx, rv, "type"); const char *tys = JS_IsString(ty) ? JS_ToCString(ctx, ty) : NULL; JS_FreeValue(ctx, ty);
        int is_reply = tys && !strcmp(tys, "reply"); if (tys) JS_FreeCString(ctx, tys);
        if (!is_reply) { JS_FreeValue(ctx, rv); continue; }
        JSValue idv = getp(ctx, rv, "id"); int64_t id = 0; JS_ToInt64(ctx, &id, idv); JS_FreeValue(ctx, idv);
        if (id < 1 || id > H.ncalls || H.calls[id - 1].state != 1) { JS_FreeValue(ctx, rv); continue; }
        Call *c = &H.calls[id - 1]; c->state = 2; H.inflight--;
        JSValue ev = getp(ctx, rv, "error"); JSValue arg; JSValue fnr;
        if (!JS_IsUndefined(ev) && !JS_IsNull(ev)) {        // bridge/limit error -> failed child result
            arg = JS_NewObject(ctx);
            JS_SetPropertyStr(ctx, arg, "isError", JS_TRUE);
            JS_SetPropertyStr(ctx, arg, "error", JS_DupValue(ctx, ev));
        } else {
            arg = getp(ctx, rv, "result");
            if (!JS_IsObject(arg)) { JS_FreeValue(ctx, arg); arg = JS_NewObject(ctx); JS_SetPropertyStr(ctx, arg, "isError", JS_TRUE);
                JS_SetPropertyStr(ctx, arg, "error", JS_NewString(ctx, "malformed tool reply")); }
            JSValue t = getp(ctx, arg, "text"); int64_t tl = 0;
            if (JS_IsString(t)) { JSValue lv = JS_GetPropertyStr(ctx, t, "length"); JS_ToInt64(ctx, &tl, lv); JS_FreeValue(ctx, lv); }
            JS_FreeValue(ctx, t); H.child_chars += tl;
            if (tl > CHILD_MAX || rlen > (size_t)CHILD_MAX * 3) { H.abort = AB_CHILD; error = strdup(ab_text[H.abort]); goto done; }
        }
        JSValue iev = getp(ctx, arg, "isError"); int is_err = JS_ToBool(ctx, iev); JS_FreeValue(ctx, iev);
        if (is_err) H.failed_children++;
        if (is_err && !c->allow_error) {
            JSValue em = getp(ctx, arg, "error"); const char *es = JS_IsString(em) ? JS_ToCString(ctx, em) : NULL; JS_FreeValue(ctx, em);
            JSValue errv = JS_NewError(ctx);
            JS_DefinePropertyValueStr(ctx, errv, "message", JS_NewString(ctx, es ? es : "tool call failed"), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
            JS_DefinePropertyValueStr(ctx, errv, "result", arg, JS_PROP_C_W_E);   // ownership moves to errv
            if (es) JS_FreeCString(ctx, es);
            arg = errv; fnr = c->rej;
        } else fnr = c->res;
        JS_FreeValue(ctx, ev);
        js_enter(); JSValue cr = JS_Call(ctx, fnr, JS_UNDEFINED, 1, (JSValueConst *)&arg); js_leave();
        JS_FreeValue(ctx, cr); JS_FreeValue(ctx, arg); JS_FreeValue(ctx, rv);
        JS_FreeValue(ctx, c->res); JS_FreeValue(ctx, c->rej); c->res = c->rej = JS_UNDEFINED;
    }
done:
    finish(error);
    fflush(stdout); _exit(0);   // one process per call: no runtime teardown (an in-app executor must JS_FreeRuntime)
    return NULL;
}

int main(void) {
    W_MS = envl("CM_WALL_MS", 60000); CPU_MS = envl("CM_CPU_MS", 2000); HEAP_MB = envl("CM_HEAP_MB", 64); STACK_KB = envl("CM_STACK_KB", 1024);
    MAX_CALLS = envl("CM_MAX_CALLS", 32); MAX_INFLIGHT = envl("CM_MAX_INFLIGHT", 4); CHILD_MAX = envl("CM_CHILD_MAX", 2097152); OUT_MAX = envl("CM_OUT_MAX", 32768);
    const char *om = getenv("CM_OUT_MODE"); OUT_FAIL = !(om && !strcmp(om, "truncate"));
    const char *cm = getenv("CM_CALL_MODE"); CALL_FAIL = !(cm && !strcmp(cm, "reject"));
    pthread_t rd, js; pthread_create(&rd, NULL, reader, NULL);
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 8 << 20);   // dedicated JS thread, 8 MiB stack
    pthread_create(&js, &at, js_main, NULL); pthread_join(js, NULL);
    return 0;
}
