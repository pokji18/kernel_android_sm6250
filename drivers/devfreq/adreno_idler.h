/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Adreno idler - force the lowest GPU frequency after a sustained
 * idle period.
 *
 * The msm-adreno-tz governor keeps the current frequency while the GPU
 * load stays below its MIN_BUSY floor, which wastes power on an idle
 * GPU. When this idler observes zero GPU busy time for longer than
 * adreno_idler_idlewait, the governor is told to drop straight to the
 * lowest frequency. Any real load clears the idle state immediately,
 * so the only possible failure mode is a conservative (low) frequency
 * while the switch back ramps up.
 *
 * Tunables (module parameters, also under
 * /sys/module/adreno_idler/parameters/ when built-in):
 *   adreno_idler_active   - master switch (default: 1)
 *   adreno_idler_idlewait - idle time in ms before forcing min (default: 50)
 */

#ifndef __ADRENO_IDLER_H
#define __ADRENO_IDLER_H

#include <linux/devfreq.h>

#ifdef CONFIG_ADRENO_IDLER
bool adreno_idler_idle(struct devfreq *devfreq, unsigned int busy_time);
#else
static inline bool adreno_idler_idle(struct devfreq *devfreq,
				     unsigned int busy_time)
{
	return false;
}
#endif

#endif /* __ADRENO_IDLER_H */
