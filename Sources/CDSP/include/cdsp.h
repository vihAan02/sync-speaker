#ifndef CDSP_H
#define CDSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// All state structs are opaque so their atomics never cross into Swift.
// Every function marked "render thread" is allocation- and lock-free.

// MARK: - Block FIFO (capture IOProc -> processing thread)

typedef struct ss_block_fifo ss_block_fifo;

ss_block_fifo *ss_block_fifo_create(int32_t channels, int32_t max_frames_per_block, int32_t block_count);
void ss_block_fifo_destroy(ss_block_fifo *fifo);
/// Producer (render thread). Returns 0 if the FIFO is full and the block was dropped.
int32_t ss_block_fifo_push(ss_block_fifo *fifo, int64_t host_ns, const float *interleaved, int32_t frames);
/// Consumer. Returns frames copied, or -1 when empty.
int32_t ss_block_fifo_pop(ss_block_fifo *fifo, int64_t *host_ns, float *interleaved_out, int32_t max_frames);
int64_t ss_block_fifo_dropped(const ss_block_fifo *fifo);

// MARK: - Timeline (absolute-frame-indexed circular buffer)

typedef struct ss_timeline ss_timeline;

/// capacity_frames is rounded up to a power of two.
ss_timeline *ss_timeline_create(int32_t channels, int64_t capacity_frames);
void ss_timeline_destroy(ss_timeline *tl);
/// Writer thread. Forgets all audio and the timing anchor.
void ss_timeline_reset(ss_timeline *tl);
/// Writer thread. Stores frames at [frame_index, frame_index+frames) and publishes the anchor:
/// frame `frame_index` is presented at cluster time `pts_ns`, and frames are `ns_per_frame` apart.
void ss_timeline_write(ss_timeline *tl, int64_t frame_index, const float *interleaved, int32_t frames,
                       int64_t pts_ns, double ns_per_frame);
int32_t ss_timeline_channels(const ss_timeline *tl);
int64_t ss_timeline_capacity(const ss_timeline *tl);

// MARK: - Playout renderer

typedef struct ss_playout ss_playout;

typedef struct ss_playout_stats {
    double error_ms;        // target minus actual read position, before correction
    double ratio_ppm;       // current drift correction
    double buffer_ms;       // audio buffered ahead of the read head
    double delay_ms;        // current (slewed) spatial delay
    float gain;             // current (smoothed) gain
    float mix_l;            // current (smoothed) left-channel weight
    float mix_r;            // current (smoothed) right-channel weight
    float peak;             // output peak since the last stats read
    int64_t underruns;
    int64_t resyncs;
    int32_t locked;         // 1 once playing against a valid anchor
} ss_playout_stats;

ss_playout *ss_playout_create(ss_timeline *tl, int32_t max_frames_per_render, int32_t overlay_capacity_frames);
void ss_playout_destroy(ss_playout *p);

// Control setters: any thread, lock-free.
void ss_playout_set_clock_map(ss_playout *p, int64_t local_ref_ns, int64_t cluster_ref_ns, double rate);
void ss_playout_set_output_latency_ns(ss_playout *p, int64_t ns);
void ss_playout_set_trim_ns(ss_playout *p, int64_t ns);
/// Spatial render targets. delay is slew-limited and gains are smoothed on the render thread.
void ss_playout_set_render(ss_playout *p, double delay_s, float gain, float mix_l, float mix_r);
void ss_playout_set_master(ss_playout *p, float master);
/// Schedules a mono one-shot (e.g. a calibration chirp) to start at `start_cluster_ns`.
/// Mixed after gain/master at unity. Returns 0 if `frames` exceeds the overlay capacity.
int32_t ss_playout_schedule_overlay(ss_playout *p, const float *mono, int32_t frames, double sample_rate,
                                    int64_t start_cluster_ns);
void ss_playout_get_stats(ss_playout *p, ss_playout_stats *out);

/// Render thread. Renders `frames` mono samples whose first sample reaches the device's
/// output stage at local host time `host_ns` (before device latency, which is added internally).
void ss_playout_render(ss_playout *p, int64_t host_ns, float *mono_out, int32_t frames, double out_sample_rate);

#ifdef __cplusplus
}
#endif

#endif
