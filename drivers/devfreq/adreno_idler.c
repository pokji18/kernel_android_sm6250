/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Adreno idler - force the lowest GPU frequency after a sustained
 * idle period. See adreno_idler.h for details.
 */

#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/types.h>

#include "adreno_idler.h"

#define IDLEWAIT_MAX_MS		10000

unsigned int adreno_idler_active = 1;
unsigned int adreno_idler_idlewait_ms = 50;

static unsigned long last_busy_jiffies;

static int param_set_idlewait(const char *val, const struct kernel_param *kp)
{
	unsigned int tmp;
	int ret;

	ret = kstrtouint(val, 0, &tmp);
	if (ret)
		return ret;
	if (tmp > IDLEWAIT_MAX_MS)
		return -EINVAL;

	return param_set_uint(val, kp);
}

static const struct kernel_param_ops param_ops_idlewait = {
	.set = param_set_idlewait,
	.get = param_get_uint,
};

module_param_named(active, adreno_idler_active, uint, 0644);
MODULE_PARM_DESC(active, "Master switch for the Adreno idler");
module_param_cb(idlewait_ms, &param_ops_idlewait,
		&adreno_idler_idlewait_ms, 0644);
MODULE_PARM_DESC(idlewait_ms, "Idle time in ms before forcing min freq");

/**
 * adreno_idler_idle() - check for a sustained GPU idle period
 * @devfreq: the GPU devfreq device (currently unused, kept for callers)
 * @busy_time: GPU busy time accumulated since the last governor poll
 *
 * Any observed busy time refreshes the idle timer. Returns true once
 * the GPU has been continuously idle for adreno_idler_idlewait_ms
 * while the idler is active.
 *
 * Return: true if the governor should drop to the lowest frequency.
 */
bool adreno_idler_idle(struct devfreq *devfreq, unsigned int busy_time)
{
	(void)devfreq;

	if (!adreno_idler_active)
		return false;

	if (busy_time) {
		last_busy_jiffies = jiffies;
		return false;
	}

	return time_after_eq(jiffies,
			     last_busy_jiffies +
			     msecs_to_jiffies(adreno_idler_idlewait_ms));
}
