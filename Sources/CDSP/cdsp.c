#include "cdsp.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static inline uint64_t d2b(double d) { uint64_t b; memcpy(&b, &d, sizeof b); return b; }
static inline double b2d(uint64_t b) { double d; memcpy(&d, &b, sizeof d); return d; }
static inline uint32_t f2b(float f) { uint32_t b; memcpy(&b, &f, sizeof b); return b; }
static inline float b2f(uint32_t b) { float f; memcpy(&f, &b, sizeof f); return f; }

static int64_t next_pow2(int64_t v) {
    int64_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

// Seqlock write helpers: odd sequence while a writer is mid-update.
#define SEQ_BEGIN(seq) atomic_fetch_add(&(seq), 1)
#define SEQ_END(seq) atomic_fetch_add(&(seq), 1)
#define SEQ_READ_TRIES 16

// MARK: - Block FIFO

struct ss_block_fifo {
    int32_t channels;
    int32_t max_frames;
    int32_t count;
    int64_t *host_ns;
    int32_t *frames;
    float *data;
    _Atomic(int32_t) head; // producer writes here
    _Atomic(int32_t) tail; // consumer reads here
    _Atomic(int64_t) dropped;
};

ss_block_fifo *ss_block_fifo_create(int32_t channels, int32_t max_frames_per_block, int32_t block_count) {
    ss_block_fifo *f = calloc(1, sizeof *f);
    if (!f) return NULL;
    f->channels = channels;
    f->max_frames = max_frames_per_block;
    f->count = block_count + 1; // one slot stays empty to distinguish full from empty
    f->host_ns = calloc((size_t)f->count, sizeof(int64_t));
    f->frames = calloc((size_t)f->count, sizeof(int32_t));
    f->data = calloc((size_t)f->count * (size_t)max_frames_per_block * (size_t)channels, sizeof(float));
    if (!f->host_ns || !f->frames || !f->data) {
        ss_block_fifo_destroy(f);
        return NULL;
    }
    return f;
}

void ss_block_fifo_destroy(ss_block_fifo *f) {
    if (!f) return;
    free(f->host_ns);
    free(f->frames);
    free(f->data);
    free(f);
}

int32_t ss_block_fifo_push(ss_block_fifo *f, int64_t host_ns, const float *interleaved, int32_t frames) {
    int32_t head = atomic_load(&f->head);
    int32_t next = (head + 1) % f->count;
    if (next == atomic_load(&f->tail) || frames > f->max_frames || frames <= 0) {
        atomic_fetch_add(&f->dropped, 1);
        return 0;
    }
    f->host_ns[head] = host_ns;
    f->frames[head] = frames;
    memcpy(f->data + (size_t)head * (size_t)f->max_frames * (size_t)f->channels, interleaved,
           (size_t)frames * (size_t)f->channels * sizeof(float));
    atomic_store(&f->head, next);
    return 1;
}

int32_t ss_block_fifo_pop(ss_block_fifo *f, int64_t *host_ns, float *out, int32_t max_frames) {
    int32_t tail = atomic_load(&f->tail);
    if (tail == atomic_load(&f->head)) return -1;
    int32_t n = f->frames[tail];
    if (n > max_frames) n = max_frames;
    *host_ns = f->host_ns[tail];
    memcpy(out, f->data + (size_t)tail * (size_t)f->max_frames * (size_t)f->channels,
           (size_t)n * (size_t)f->channels * sizeof(float));
    atomic_store(&f->tail, (tail + 1) % f->count);
    return n;
}

int64_t ss_block_fifo_dropped(const ss_block_fifo *f) {
    return atomic_load(&((ss_block_fifo *)f)->dropped);
}

// MARK: - Timeline

struct ss_timeline {
    int32_t channels;
    int64_t capacity;
    int64_t mask;
    float *data;
    _Atomic(int64_t) write_end;
    _Atomic(uint64_t) seq;
    _Atomic(int64_t) anchor_index;
    _Atomic(int64_t) anchor_pts;
    _Atomic(uint64_t) anchor_npf_bits;
    _Atomic(int32_t) has_anchor;
    _Atomic(uint32_t) generation;
};

ss_timeline *ss_timeline_create(int32_t channels, int64_t capacity_frames) {
    ss_timeline *tl = calloc(1, sizeof *tl);
    if (!tl) return NULL;
    tl->channels = channels;
    tl->capacity = next_pow2(capacity_frames);
    tl->mask = tl->capacity - 1;
    tl->data = calloc((size_t)(tl->capacity * channels), sizeof(float));
    if (!tl->data) {
        free(tl);
        return NULL;
    }
    return tl;
}

void ss_timeline_destroy(ss_timeline *tl) {
    if (!tl) return;
    free(tl->data);
    free(tl);
}

void ss_timeline_reset(ss_timeline *tl) {
    SEQ_BEGIN(tl->seq);
    atomic_store(&tl->has_anchor, 0);
    atomic_store(&tl->write_end, 0);
    atomic_fetch_add(&tl->generation, 1);
    SEQ_END(tl->seq);
    memset(tl->data, 0, (size_t)(tl->capacity * tl->channels) * sizeof(float));
}

void ss_timeline_write(ss_timeline *tl, int64_t index, const float *src, int32_t frames, int64_t pts_ns,
                       double ns_per_frame) {
    const int64_t ch = tl->channels;
    int64_t write_end = atomic_load(&tl->write_end);
    int has = atomic_load(&tl->has_anchor);

    if (has && index > write_end) {
        // Silence the gap so stale audio from a previous lap is never played.
        int64_t gap = index - write_end;
        if (gap > tl->capacity) gap = tl->capacity;
        for (int64_t i = index - gap; i < index; i++) {
            memset(tl->data + (i & tl->mask) * ch, 0, (size_t)ch * sizeof(float));
        }
    }
    for (int32_t k = 0; k < frames; k++) {
        memcpy(tl->data + ((index + k) & tl->mask) * ch, src + (int64_t)k * ch, (size_t)ch * sizeof(float));
    }

    SEQ_BEGIN(tl->seq);
    if (!has || index + frames > write_end) atomic_store(&tl->write_end, index + frames);
    atomic_store(&tl->anchor_index, index);
    atomic_store(&tl->anchor_pts, pts_ns);
    atomic_store(&tl->anchor_npf_bits, d2b(ns_per_frame));
    atomic_store(&tl->has_anchor, 1);
    SEQ_END(tl->seq);
}

int32_t ss_timeline_channels(const ss_timeline *tl) { return tl->channels; }
int64_t ss_timeline_capacity(const ss_timeline *tl) { return tl->capacity; }

typedef struct {
    int64_t index;
    int64_t pts;
    double npf;
    int64_t write_end;
    uint32_t generation;
    int has;
} timeline_anchor;

static int timeline_read_anchor(ss_timeline *tl, timeline_anchor *a) {
    for (int i = 0; i < SEQ_READ_TRIES; i++) {
        uint64_t s1 = atomic_load(&tl->seq);
        if (s1 & 1) continue;
        timeline_anchor t = {
            .index = atomic_load(&tl->anchor_index),
            .pts = atomic_load(&tl->anchor_pts),
            .npf = b2d(atomic_load(&tl->anchor_npf_bits)),
            .write_end = atomic_load(&tl->write_end),
            .generation = atomic_load(&tl->generation),
            .has = atomic_load(&tl->has_anchor),
        };
        if (s1 == atomic_load(&tl->seq)) {
            *a = t;
            return 1;
        }
    }
    return 0;
}

// MARK: - Playout

enum { STAT_ERROR, STAT_RATIO, STAT_BUFFER, STAT_DELAY, STAT_GAIN, STAT_MIXL, STAT_MIXR, STAT_COUNT };

// Drift controller: error time constant ~1/KP seconds, critically damped integral.
static const double KP = 0.1;
static const double KI = KP * KP / 4.0;
static const double MAX_CORRECTION = 200e-6;
// Network jitter never reaches the controller (the buffer absorbs it), so errors this large come from real
// timing steps (latency change, clock-map jump) and are fixed by jumping with a short fade instead of slewing.
static const double RESYNC_SECONDS = 0.005;
static const double DELAY_SLEW = 0.001; // seconds of delay change per second (<2 cents pitch)
static const double GAIN_TAU = 0.03;
static const double MIX_TAU = 0.15;

struct ss_playout {
    ss_timeline *tl;

    float *overlay;
    int32_t overlay_capacity;
    _Atomic(int32_t) overlay_armed;
    _Atomic(int32_t) overlay_len;
    _Atomic(int64_t) overlay_start;
    _Atomic(uint64_t) overlay_npf_bits;

    _Atomic(uint64_t) clock_seq;
    _Atomic(int64_t) clock_local;
    _Atomic(int64_t) clock_cluster;
    _Atomic(uint64_t) clock_rate_bits;
    _Atomic(int64_t) out_latency_ns;
    _Atomic(int64_t) trim_ns;

    _Atomic(uint64_t) target_seq;
    _Atomic(uint64_t) target_delay_bits;
    _Atomic(uint32_t) target_gain_bits;
    _Atomic(uint32_t) target_mixl_bits;
    _Atomic(uint32_t) target_mixr_bits;
    _Atomic(uint32_t) master_bits;

    _Atomic(uint64_t) stats[STAT_COUNT];
    _Atomic(uint32_t) peak_bits;
    _Atomic(int64_t) underruns;
    _Atomic(int64_t) resyncs;
    _Atomic(int32_t) locked_flag;

    // Render-thread state.
    int locked;
    uint32_t generation;
    double pos;
    double integral;
    double delay_s;
    float gain, mix_l, mix_r, master;
    int64_t last_clock_local, last_clock_cluster;
    double last_clock_rate;
    double last_delay;
    float last_gain, last_mixl, last_mixr;
};

ss_playout *ss_playout_create(ss_timeline *tl, int32_t max_frames, int32_t overlay_capacity) {
    (void)max_frames;
    ss_playout *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->tl = tl;
    p->overlay_capacity = overlay_capacity;
    p->overlay = calloc((size_t)overlay_capacity, sizeof(float));
    if (!p->overlay) {
        free(p);
        return NULL;
    }
    atomic_store(&p->clock_rate_bits, d2b(1.0));
    atomic_store(&p->target_gain_bits, f2b(1.0f));
    atomic_store(&p->target_mixl_bits, f2b(0.5f));
    atomic_store(&p->target_mixr_bits, f2b(0.5f));
    atomic_store(&p->master_bits, f2b(1.0f));
    p->last_clock_rate = 1.0;
    p->last_gain = 1.0f;
    p->last_mixl = p->last_mixr = 0.5f;
    p->mix_l = p->mix_r = 0.5f;
    p->master = 1.0f;
    p->generation = UINT32_MAX;
    return p;
}

void ss_playout_destroy(ss_playout *p) {
    if (!p) return;
    free(p->overlay);
    free(p);
}

void ss_playout_set_clock_map(ss_playout *p, int64_t local_ref_ns, int64_t cluster_ref_ns, double rate) {
    SEQ_BEGIN(p->clock_seq);
    atomic_store(&p->clock_local, local_ref_ns);
    atomic_store(&p->clock_cluster, cluster_ref_ns);
    atomic_store(&p->clock_rate_bits, d2b(rate));
    SEQ_END(p->clock_seq);
}

void ss_playout_set_output_latency_ns(ss_playout *p, int64_t ns) { atomic_store(&p->out_latency_ns, ns); }
void ss_playout_set_trim_ns(ss_playout *p, int64_t ns) { atomic_store(&p->trim_ns, ns); }
void ss_playout_set_master(ss_playout *p, float master) { atomic_store(&p->master_bits, f2b(master)); }

void ss_playout_set_render(ss_playout *p, double delay_s, float gain, float mix_l, float mix_r) {
    SEQ_BEGIN(p->target_seq);
    atomic_store(&p->target_delay_bits, d2b(delay_s));
    atomic_store(&p->target_gain_bits, f2b(gain));
    atomic_store(&p->target_mixl_bits, f2b(mix_l));
    atomic_store(&p->target_mixr_bits, f2b(mix_r));
    SEQ_END(p->target_seq);
}

int32_t ss_playout_schedule_overlay(ss_playout *p, const float *mono, int32_t frames, double sample_rate,
                                    int64_t start_cluster_ns) {
    if (frames > p->overlay_capacity || frames <= 0 || sample_rate <= 0) return 0;
    atomic_store(&p->overlay_armed, 0);
    memcpy(p->overlay, mono, (size_t)frames * sizeof(float));
    atomic_store(&p->overlay_len, frames);
    atomic_store(&p->overlay_start, start_cluster_ns);
    atomic_store(&p->overlay_npf_bits, d2b(1e9 / sample_rate));
    atomic_store(&p->overlay_armed, 1);
    return 1;
}

void ss_playout_get_stats(ss_playout *p, ss_playout_stats *out) {
    out->error_ms = b2d(atomic_load(&p->stats[STAT_ERROR]));
    out->ratio_ppm = b2d(atomic_load(&p->stats[STAT_RATIO]));
    out->buffer_ms = b2d(atomic_load(&p->stats[STAT_BUFFER]));
    out->delay_ms = b2d(atomic_load(&p->stats[STAT_DELAY]));
    out->gain = (float)b2d(atomic_load(&p->stats[STAT_GAIN]));
    out->mix_l = (float)b2d(atomic_load(&p->stats[STAT_MIXL]));
    out->mix_r = (float)b2d(atomic_load(&p->stats[STAT_MIXR]));
    out->peak = b2f(atomic_exchange(&p->peak_bits, 0));
    out->underruns = atomic_load(&p->underruns);
    out->resyncs = atomic_load(&p->resyncs);
    out->locked = atomic_load(&p->locked_flag);
}

static inline float sample_at(const float *data, int64_t mask, int32_t ch, int64_t i, int32_t c) {
    return data[(i & mask) * ch + c];
}

/// One-pole smoothing that lands exactly on the target (avoids denormals when fading to zero).
static inline float smooth(float current, float target, float coeff) {
    float next = current + (target - current) * coeff;
    return fabsf(target - next) < 1e-6f ? target : next;
}

static inline float cubic(float xm1, float x0, float x1, float x2, float t) {
    float c1 = 0.5f * (x1 - xm1);
    float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
    float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

void ss_playout_render(ss_playout *p, int64_t host_ns, float *out, int32_t frames, double out_rate) {
    // Clock map (keep last good values if a writer is mid-update).
    for (int i = 0; i < SEQ_READ_TRIES; i++) {
        uint64_t s1 = atomic_load(&p->clock_seq);
        if (s1 & 1) continue;
        int64_t l = atomic_load(&p->clock_local);
        int64_t c = atomic_load(&p->clock_cluster);
        double r = b2d(atomic_load(&p->clock_rate_bits));
        if (s1 == atomic_load(&p->clock_seq)) {
            p->last_clock_local = l;
            p->last_clock_cluster = c;
            p->last_clock_rate = r;
            break;
        }
    }
    for (int i = 0; i < SEQ_READ_TRIES; i++) {
        uint64_t s1 = atomic_load(&p->target_seq);
        if (s1 & 1) continue;
        double d = b2d(atomic_load(&p->target_delay_bits));
        float g = b2f(atomic_load(&p->target_gain_bits));
        float l = b2f(atomic_load(&p->target_mixl_bits));
        float r = b2f(atomic_load(&p->target_mixr_bits));
        if (s1 == atomic_load(&p->target_seq)) {
            p->last_delay = d;
            p->last_gain = g;
            p->last_mixl = l;
            p->last_mixr = r;
            break;
        }
    }
    const float master_target = b2f(atomic_load(&p->master_bits));
    const double rate = p->last_clock_rate;
    // Local ns from the clock reference to when the first sample leaves the speaker.
    const int64_t d_local =
        host_ns + atomic_load(&p->out_latency_ns) + atomic_load(&p->trim_ns) - p->last_clock_local;
    const double out_ns = 1e9 / out_rate * rate; // cluster ns per output frame

    const float a_gain = (float)(1.0 - exp(-1.0 / (GAIN_TAU * out_rate)));
    const float a_mix = (float)(1.0 - exp(-1.0 / (MIX_TAU * out_rate)));
    const double max_slew = DELAY_SLEW / out_rate;
    float peak = 0.0f;

    timeline_anchor a = {0};
    int have_audio = timeline_read_anchor(p->tl, &a) && a.has && a.npf > 0.0;

    if (!have_audio) {
        p->locked = 0;
        memset(out, 0, (size_t)frames * sizeof(float));
    } else {
        if (a.generation != p->generation) {
            p->locked = 0;
            p->generation = a.generation;
        }
        const double src_rate = 1e9 / a.npf;
        const double since_anchor = (double)(p->last_clock_cluster - a.pts) + (double)d_local * rate;
        const double target = (double)a.index + since_anchor / a.npf;
        double err = target - p->pos;

        if (!p->locked || fabs(err) > RESYNC_SECONDS * src_rate) {
            if (p->locked) atomic_fetch_add(&p->resyncs, 1);
            p->pos = target;
            p->integral = 0.0;
            p->gain = 0.0f; // fade in after a jump
            p->delay_s = p->last_delay;
            p->locked = 1;
            err = 0.0;
        }

        const double err_s = err / src_rate;
        p->integral += KI * err_s * ((double)frames / out_rate);
        if (p->integral > MAX_CORRECTION) p->integral = MAX_CORRECTION;
        if (p->integral < -MAX_CORRECTION) p->integral = -MAX_CORRECTION;
        double correction = KP * err_s + p->integral;
        if (correction > MAX_CORRECTION) correction = MAX_CORRECTION;
        if (correction < -MAX_CORRECTION) correction = -MAX_CORRECTION;
        const double step = out_ns / a.npf * (1.0 + correction);

        const ss_timeline *tl = p->tl;
        const int32_t ch = tl->channels;
        const int64_t lo = a.write_end - tl->capacity + 1;
        const int64_t hi = a.write_end - 3;
        int underrun = 0;

        for (int32_t k = 0; k < frames; k++) {
            double dd = p->last_delay - p->delay_s;
            if (dd > max_slew) dd = max_slew;
            if (dd < -max_slew) dd = -max_slew;
            p->delay_s += dd;
            p->gain = smooth(p->gain, p->last_gain, a_gain);
            p->master = smooth(p->master, master_target, a_gain);
            p->mix_l = smooth(p->mix_l, p->last_mixl, a_mix);
            p->mix_r = smooth(p->mix_r, p->last_mixr, a_mix);

            const double rp = p->pos - p->delay_s * src_rate;
            const double fl = floor(rp);
            const int64_t i = (int64_t)fl;
            const float t = (float)(rp - fl);
            float left = 0.0f, right = 0.0f;
            if (i >= lo && i <= hi) {
                left = cubic(sample_at(tl->data, tl->mask, ch, i - 1, 0), sample_at(tl->data, tl->mask, ch, i, 0),
                             sample_at(tl->data, tl->mask, ch, i + 1, 0), sample_at(tl->data, tl->mask, ch, i + 2, 0), t);
                if (ch > 1) {
                    right = cubic(sample_at(tl->data, tl->mask, ch, i - 1, 1), sample_at(tl->data, tl->mask, ch, i, 1),
                                  sample_at(tl->data, tl->mask, ch, i + 1, 1), sample_at(tl->data, tl->mask, ch, i + 2, 1), t);
                } else {
                    right = left;
                }
            } else {
                underrun = 1;
            }
            out[k] = (p->mix_l * left + p->mix_r * right) * p->gain * p->master;
            p->pos += step;
        }
        if (underrun) atomic_fetch_add(&p->underruns, 1);

        atomic_store(&p->stats[STAT_ERROR], d2b(err_s * 1000.0));
        atomic_store(&p->stats[STAT_RATIO], d2b(correction * 1e6));
        atomic_store(&p->stats[STAT_BUFFER], d2b(((double)a.write_end - p->pos) / src_rate * 1000.0));
    }
    atomic_store(&p->locked_flag, p->locked);
    atomic_store(&p->stats[STAT_DELAY], d2b(p->delay_s * 1000.0));
    atomic_store(&p->stats[STAT_GAIN], d2b(p->gain));
    atomic_store(&p->stats[STAT_MIXL], d2b(p->mix_l));
    atomic_store(&p->stats[STAT_MIXR], d2b(p->mix_r));

    // One-shot overlay, positioned in cluster time independently of the music stream.
    if (atomic_load(&p->overlay_armed)) {
        const int32_t len = atomic_load(&p->overlay_len);
        const double onpf = b2d(atomic_load(&p->overlay_npf_bits));
        const double t0 = (double)(p->last_clock_cluster - atomic_load(&p->overlay_start)) + (double)d_local * rate;
        for (int32_t k = 0; k < frames; k++) {
            double x = (t0 + (double)k * out_ns) / onpf;
            if (x > -1e-6 && x < 0.0) x = 0.0; // absorb rounding at the exact start frame
            if (x >= 0.0 && x < (double)(len - 1)) {
                const int32_t i = (int32_t)x;
                const float t = (float)(x - (double)i);
                out[k] += p->overlay[i] + (p->overlay[i + 1] - p->overlay[i]) * t;
            }
        }
        if ((t0 + (double)frames * out_ns) / onpf >= (double)len) atomic_store(&p->overlay_armed, 0);
    }

    for (int32_t k = 0; k < frames; k++) {
        const float v = fabsf(out[k]);
        if (v > peak) peak = v;
    }
    if (peak > b2f(atomic_load(&p->peak_bits))) atomic_store(&p->peak_bits, f2b(peak));
}
