#ifndef MT_DETECT_H
#define MT_DETECT_H

#include <stdint.h>
#include "mt_net.h"

/* Shared with the camera demo: stage the packed weights into the uncached
 * scratch window and build the four layer descriptors from the packed cfg. */
void det_copy_to_scratch(uint32_t off, const unsigned char *src, uint32_t n);
void det_make_layers(net_layer_t *L);

#endif
