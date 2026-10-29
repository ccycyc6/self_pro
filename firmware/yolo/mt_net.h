#ifndef MT_NET_H
#define MT_NET_H

#include <stdint.h>

/* -----------------------------------------------------------------------------
 * Shared pieces of the miniTensor convolution engine.
 *
 * The scratch window, the UB row allocation and the layer descriptor are used
 * by both the LCG-weight regression (mt_net.c) and the packed-weight deployment
 * (mt_detect.c), so they live here rather than being duplicated.
 * -------------------------------------------------------------------------- */

/* Scratch-window layout (byte offsets inside the 64 KiB uncached alias). */
#define PAD_BUF     0x0000u   /* 16 KiB: kx-shifted activations */
#define OUT_BUF     0x4000u   /*  8 KiB: conv results           */
#define MID_BUF     0x6000u   /*  4 KiB: pooled intermediates   */
#define NET_WT      0x7000u   /*  4 KiB: packed weight rows     */
#define NET_BIAS    0x8000u
#define NET_CFG     0x8400u
#define NET_IMAGE   0x8800u   /*  4 KiB: the input image        */

/* UB row allocation (256 rows of 16 bytes). */
#define UB_WT       0u        /* up to 144 weight rows          */
#define UB_C        148u      /* up to  64 C rows               */
#define UB_BIAS     216u      /* up to  16 bias rows            */
#define UB_CFG      232u
#define UB_A        236u      /* 4 activation rows              */
#define UB_OUT      240u      /* up to 8 output rows            */
#define UB_SKIP     248u      /* up to 8 skip (residual) rows   */

typedef struct {
    uint16_t h, w;         /* input spatial extent            */
    uint16_t c_in;         /* input channels (multiple of 4)  */
    uint16_t c_out;        /* output channels (multiple of 4) */
    uint8_t  k;            /* kernel (1 or 3)                 */
    uint8_t  pad;
    uint8_t  relu;
    int16_t  mult;
    uint8_t  shift;
    int8_t   zp;
    uint32_t src_off;      /* previous layer output [g][h][w][4] */
    uint32_t pad_off;      /* zero-padded copy used for A rows   */
    uint32_t out_off;      /* this layer's result                */
    uint32_t wt_off;
    uint32_t bias_off;
    uint32_t cfg_off;

    /* Output-channel groups per weight tile.  A layer's weight rows must
     * otherwise fit in UB_WT (144 rows), which caps a 3x3 layer at
     * ng*k*k*nm <= 144 -- far below what a real YOLO layer needs (512->512 3x3
     * is 147456 rows).  net_conv reloads the tile's weights per group tile, so
     * layer weight volume is decoupled from UB capacity.  0 means "all groups",
     * which is what every layer of the small networks wants.  Appended at the
     * end of the struct so existing positional initialisers stay valid. */
    uint8_t  nmt;

    /* Optional residual (skip) connection, as used by every CSPDarknet block.
     * After the epilogue has written a row of output into UB_OUT, the matching
     * row of the skip tensor is loaded and combined with the MT_VECTOR unit:
     *   0 = none, 1 = out += skip, 2 = out = relu(out + skip).
     * Also appended at the end so existing positional initialisers stay valid. */
    uint32_t skip_off;     /* skip tensor, [g][h][w][4], same shape as out */
    uint8_t  skip;

    /* LeakyReLU, without any new hardware.  For 0 < a < 1,
     *     leaky(x) = max(x, a*x)
     * and the multiplier in the epilogue config is a SIGNED 16-bit field, so
     * running the epilogue twice over the same C tile -- once with mult, once
     * with round(mult*a) -- followed by the VPU's signed MAX8 gives exactly
     * leaky(x).  Cost is one extra epilogue and one MAX8 per tile, not a second
     * convolution.  Both configs must have relu OFF: with relu on, the negative
     * branch would already have been clamped to 0 and the max would be wrong.
     * When set, cfg_off must point at TWO config rows and the second one holds
     * the a-scaled multiplier. */
    uint8_t  leaky;

    /* Output width padded up to a multiple of 4, and the SOURCE buffer's row
     * stride.  net_conv addresses activations in 4-pixel tiles (ntiles = W/4),
     * so a layer whose output is 6 wide cannot be tiled at all -- and 9 of the
     * 13 convolutions in tiny-yolov3 have a width that is not a multiple of 4.
     * wpad lets such a layer be computed at the next multiple of 4 and the
     * padding simply ignored by the consumer, which reads only the first w
     * pixels of each row because src_w carries the stride.  Zero means "no
     * padding" and reproduces the previous behaviour exactly.
     * H needs no equivalent: the row loop runs per row, not per 4 rows. */
    uint16_t src_w;        /* source row stride (0 -> same as w)  */
    uint16_t wpad;         /* output row stride, multiple of 4    */

    /* Absolute base for every *_off field in this descriptor.  0 means the
     * 64 KiB miniTensor scratch (MT_BUF_BASE), which is what all the small
     * tests want and what every descriptor got before this field existed.
     *
     * A network whose activations do not fit in 64 KiB -- tiny-yolov3's stem
     * produces 256 KiB at 128x128 -- points this at the uncached extension
     * window instead.  The weight blob already lives there, so a layer can
     * then read its weights straight out of the blob with no staging copy.
     * Offsets stay relative, which is why adding this changed no existing
     * behaviour and no existing test needed touching. */
    uint32_t base;

    /* Which UB port the residual used, exposed for the tests' UB budgeting. */
} net_layer_t;

/* UB_WT holds 144 rows; ntap = k*k*ng taps is how many weight rows one output
 * group needs. */
#define MT_UB_WT_ROWS   144u
#define MT_MAX_TAP      160u   /* supports up to 64 input channels at k=3 */

/* Build the kx-shifted activation buffer and run the layer.  net_conv queues
 * every command through mt_push() and drains once at the end. */
void net_pad(const net_layer_t *L);
int  net_conv(const net_layer_t *L, uint32_t *cmds);

#ifdef MT_PROF
extern uint32_t prof_wt, prof_gemm, prof_epi;
#endif

/* 2x2 max pooling over the [g][h][w][4] activation layout. */
/* base is the absolute origin the offsets are relative to (pass MT_BUF_BASE
 * for the scratch). */
void net_pool2(uint32_t base, uint32_t src_off, uint32_t dst_off, uint32_t g_count,
               uint32_t h, uint32_t w, uint32_t sw, uint32_t dw);

/* k x k max pool with an arbitrary stride (2x2/2 is the usual downsample;
 * tiny-yolov3's eleventh layer is 2x2 stride 1). */
void net_pool_k(uint32_t base, uint32_t src_off, uint32_t dst_off, uint32_t g_count,
                uint32_t h, uint32_t w, uint32_t k, uint32_t stride,
                uint32_t sw, uint32_t dw);

/* ONNX SAME_UPPER max pool: output extent ceil(h/stride) x ceil(w/stride), the
 * window is clipped at the bottom/right edge (out-of-range taps contribute
 * -inf, i.e. they are simply skipped).  This is the real semantics of
 * tiny-yolov3's 2x2 stride-1 pool: ONNX gives every pool auto_pad=SAME_UPPER,
 * so that layer does NOT shrink the map (the earlier net_pool_k shrank it by
 * one, which is what a pads=0 pool would do). */
void net_pool_k_same(uint32_t base, uint32_t src_off, uint32_t dst_off,
                     uint32_t g_count, uint32_t h, uint32_t w, uint32_t k,
                     uint32_t stride, uint32_t sw, uint32_t dw);

/* Nearest-neighbour 2x upsampling (ONNX Resize, asymmetric + floor), used by
 * tiny-yolov3's FPN route.  Output is 2h x 2w with stride dw. */
void net_upsample2(uint32_t base, uint32_t src_off, uint32_t dst_off, uint32_t g_count,
                   uint32_t h, uint32_t w, uint32_t sw, uint32_t dw);

/* Concatenate two channel-group runs in the [g][h][w][4] layout.  src2's run
 * follows src1's, both at the same spatial extent. */
void net_concat2(uint32_t base, uint32_t dst_off,
                 uint32_t src1_off, uint32_t g1, uint32_t src2_off, uint32_t g2,
                 uint32_t h, uint32_t w);

#endif /* MT_NET_H */
