/*
 * CPUFreq governor based on scheduler-provided CPU utilization data,
 * tuned for power efficiency ("pwrutilx" flavor).
 *
 * Based on cpufreq_schedutil.c.
 * Copyright (C) 2016, Intel Corporation
 * Author: Rafael J. Wysocki <rafael.j.wysocki@intel.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/cpufreq.h>
#include <linux/kthread.h>
#include <uapi/linux/sched/types.h>
#include <linux/slab.h>
#include <trace/events/power.h>
#include <linux/sched/sysctl.h>
#include "sched.h"

#define SUGOV_KTHREAD_PRIORITY	50

struct pwr_tunables {
	struct gov_attr_set attr_set;
	unsigned int		up_rate_limit_us;
	unsigned int		down_rate_limit_us;
	bool iowait_boost_enable;
	unsigned int hispeed_load;
	unsigned int hispeed_freq;
	bool pl;
};

struct pwr_policy {
	struct cpufreq_policy *policy;

	struct pwr_tunables *tunables;
	struct list_head tunables_hook;

	raw_spinlock_t update_lock;  /* For shared policies */
	u64 last_freq_update_time;
	s64			min_rate_limit_ns;
	s64			up_rate_delay_ns;
	s64			down_rate_delay_ns;
	s64 freq_update_delay_ns;
	u64 last_ws;
	u64 curr_cycles;
	u64 last_cyc_update_time;
	unsigned long avg_cap;
	unsigned int next_freq;
	unsigned int cached_raw_freq;
	unsigned int prev_cached_raw_freq;
	unsigned long hispeed_util;
	unsigned long max;

	/* The next fields are only needed if fast switch cannot be used. */
	struct irq_work irq_work;
	struct kthread_work work;
	struct mutex work_lock;
	struct kthread_worker worker;
	struct task_struct *thread;
	bool work_in_progress;

	bool need_freq_update;
};

struct pwr_cpu {
	struct update_util_data update_util;
	struct pwr_policy *sg_policy;
	unsigned int cpu;

	bool iowait_boost_pending;
	unsigned int iowait_boost;
	unsigned int iowait_boost_max;
	u64 last_update;

	struct sched_walt_cpu_load walt_load;

	/* The fields below are only needed when sharing a policy. */
	unsigned long util;
	unsigned long max;
	unsigned int flags;

	/* The field below is for single-CPU policies only. */
#ifdef CONFIG_NO_HZ_COMMON
	unsigned long saved_idle_calls;
#endif
};

static DEFINE_PER_CPU(struct pwr_cpu, pwr_cpu);
static unsigned int stale_ns;
static DEFINE_PER_CPU(struct pwr_tunables *, cached_tunables);

/************************ Governor internals ***********************/

static bool pwr_should_update_freq(struct pwr_policy *sg_policy, u64 time)
{
	s64 delta_ns;

	/*
	 * Since cpufreq_update_util() is called with rq->lock held for
	 * the @target_cpu, our per-cpu data is fully serialized.
	 *
	 * However, drivers cannot in general deal with cross-cpu
	 * requests, so while get_next_freq() will work, our
	 * pwr_update_commit() call may not for the fast switching platforms.
	 *
	 * Hence stop here for remote requests if they aren't supported
	 * by the hardware, as calculating the frequency is pointless if
	 * we cannot in fact act on it.
	 *
	 * For the slow switching platforms, the kthread is always scheduled on
	 * the right set of CPUs and any CPU can find the next frequency and
	 * schedule the kthread.
	 */
	if (sg_policy->policy->fast_switch_enabled &&
	    !cpufreq_can_do_remote_dvfs(sg_policy->policy))
		return false;

	if (unlikely(sg_policy->need_freq_update)) {
		sg_policy->need_freq_update = false;
		/*
		 * This happens when limits change, so forget the previous
		 * next_freq value and force an update.
		 */
		sg_policy->next_freq = UINT_MAX;
		return true;
	}

	/* If the last frequency wasn't set yet then we can still amend it */
	if (sg_policy->work_in_progress)
		return true;

	/* No need to recalculate next freq for min_rate_limit_us
	 * at least. However we might still decide to further rate
	 * limit once frequency change direction is decided, according
	 * to the separate rate limits.
	 */

	delta_ns = time - sg_policy->last_freq_update_time;
	return delta_ns >= sg_policy->min_rate_limit_ns;
}

static bool pwr_up_down_rate_limit(struct pwr_policy *sg_policy, u64 time,
				     unsigned int next_freq)
{
	s64 delta_ns;

	delta_ns = time - sg_policy->last_freq_update_time;

	if (next_freq > sg_policy->next_freq &&
	    delta_ns < sg_policy->up_rate_delay_ns)
		return true;

	if (next_freq < sg_policy->next_freq &&
	    delta_ns < sg_policy->down_rate_delay_ns)
		return true;

	return false;
}

static inline bool use_pelt(void)
{
#ifdef CONFIG_SCHED_WALT
	return (!sysctl_sched_use_walt_cpu_util || walt_disabled);
#else
	return true;
#endif
}

static unsigned long freq_to_util(struct pwr_policy *sg_policy,
				  unsigned int freq)
{
	return mult_frac(sg_policy->max, freq,
			 sg_policy->policy->cpuinfo.max_freq);
}

#define KHZ 1000
static void pwr_track_cycles(struct pwr_policy *sg_policy,
				unsigned int prev_freq,
				u64 upto)
{
	u64 delta_ns, cycles;

	if (unlikely(!sysctl_sched_use_walt_cpu_util))
		return;

	/* Track cycles in current window */
	delta_ns = upto - sg_policy->last_cyc_update_time;
	delta_ns *= prev_freq;
	do_div(delta_ns, (NSEC_PER_SEC / KHZ));
	cycles = delta_ns;
	sg_policy->curr_cycles += cycles;
	sg_policy->last_cyc_update_time = upto;
}

static void pwr_calc_avg_cap(struct pwr_policy *sg_policy, u64 curr_ws,
				unsigned int prev_freq)
{
	u64 last_ws = sg_policy->last_ws;
	unsigned int avg_freq;

	if (unlikely(!sysctl_sched_use_walt_cpu_util))
		return;

	BUG_ON(curr_ws < last_ws);
	if (curr_ws <= last_ws)
		return;

	/* If we skipped some windows */
	if (curr_ws > (last_ws + sched_ravg_window)) {
		avg_freq = prev_freq;
		/* Reset tracking history */
		sg_policy->last_cyc_update_time = curr_ws;
	} else {
		pwr_track_cycles(sg_policy, prev_freq, curr_ws);
		avg_freq = sg_policy->curr_cycles;
		avg_freq /= sched_ravg_window / (NSEC_PER_SEC / KHZ);
	}
	sg_policy->avg_cap = freq_to_util(sg_policy, avg_freq);
	sg_policy->curr_cycles = 0;
	sg_policy->last_ws = curr_ws;
}

static void pwr_update_commit(struct pwr_policy *sg_policy, u64 time,
				unsigned int next_freq)
{
	struct cpufreq_policy *policy = sg_policy->policy;
	unsigned int cpu;

	if (sg_policy->next_freq == next_freq)
		return;

	if (pwr_up_down_rate_limit(sg_policy, time, next_freq)) {
		/* Don't cache a raw freq that didn't become next_freq */
		sg_policy->cached_raw_freq = 0;
		return;
	}

	sg_policy->next_freq = next_freq;
	sg_policy->last_freq_update_time = time;

	if (policy->fast_switch_enabled) {
		next_freq = cpufreq_driver_fast_switch(policy, next_freq);
		if (!next_freq)
			return;

		policy->cur = next_freq;
	} else {
		if (use_pelt())
			sg_policy->work_in_progress = true;
		irq_work_queue(&sg_policy->irq_work);
	}
}

#define TARGET_LOAD 80
/**
 * get_next_freq - Compute a new frequency for a given cpufreq policy.
 * @sg_policy: schedutil policy object to compute the new frequency for.
 * @util: Current CPU utilization.
 * @max: CPU capacity.
 *
 * If the utilization is frequency-invariant, choose the new frequency to be
 * proportional to it, that is
 *
 * next_freq = C * max_freq * util / max
 *
 * Otherwise, approximate the would-be frequency-invariant utilization by
 * util_raw * (curr_freq / max_freq) which leads to
 *
 * next_freq = C * curr_freq * util_raw / max
 *
 * Take C = 1.25 for the frequency tipping point at (util / max) = 0.8.
 *
 * The lowest driver-supported frequency which is equal or greater than the raw
 * next_freq (as calculated above) is returned, subject to policy min/max and
 * cpufreq driver limitations.
 */
static unsigned int get_next_freq(struct pwr_policy *sg_policy,
				  unsigned long util, unsigned long max)
{
	struct cpufreq_policy *policy = sg_policy->policy;
	unsigned int freq = arch_scale_freq_invariant() ?
				policy->cpuinfo.max_freq : policy->cur;
	unsigned int idx, l_freq, h_freq;

	freq = (freq + (freq >> 2)) * util / max;

	if (freq == sg_policy->cached_raw_freq && sg_policy->next_freq != UINT_MAX)
		return sg_policy->next_freq;
	sg_policy->prev_cached_raw_freq = sg_policy->cached_raw_freq;
	sg_policy->cached_raw_freq = freq;
	l_freq = cpufreq_driver_resolve_freq(policy, freq);
	idx = cpufreq_frequency_table_target(policy, freq, CPUFREQ_RELATION_H);
	h_freq = policy->freq_table[idx].frequency;
	h_freq = clamp(h_freq, policy->min, policy->max);
	if (l_freq <= h_freq || l_freq == policy->min)
		return l_freq;

	/*
	 * Use the frequency step below if the calculated frequency is <20%
	 * higher than it.
	 */
	if (mult_frac(100, freq - h_freq, l_freq - h_freq) < 20)
		return h_freq;

	return l_freq;
}

static void pwr_get_util(unsigned long *util, unsigned long *max, int cpu,
			   u64 time)
{
	struct rq *rq = cpu_rq(cpu);
	unsigned long max_cap, rt;
	struct pwr_cpu *loadcpu = &per_cpu(pwr_cpu, cpu);
	s64 delta;

	max_cap = arch_scale_cpu_capacity(NULL, cpu);
	*max = max_cap;

	*util = boosted_cpu_util(cpu, &loadcpu->walt_load);

	if (likely(use_pelt())) {
		sched_avg_update(rq);
		delta = time - rq->age_stamp;
		if (unlikely(delta < 0))
			delta = 0;
		rt = div64_u64(rq->rt_avg, sched_avg_period() + delta);
		rt = (rt * max_cap) >> SCHED_CAPACITY_SHIFT;
		*util = min(*util + rt, max_cap);
	}
}

static void pwr_set_iowait_boost(struct pwr_cpu *sg_cpu, u64 time,
				   unsigned int flags)
{
	struct pwr_policy *sg_policy = sg_cpu->sg_policy;

	if (!sg_policy->tunables->iowait_boost_enable)
		return;

	if (flags & SCHED_CPUFREQ_IOWAIT) {
		if (sg_cpu->iowait_boost_pending)
			return;

		sg_cpu->iowait_boost_pending = true;

		if (sg_cpu->iowait_boost) {
			sg_cpu->iowait_boost <<= 1;
			if (sg_cpu->iowait_boost > sg_cpu->iowait_boost_max)
				sg_cpu->iowait_boost = sg_cpu->iowait_boost_max;
		} else {
			sg_cpu->iowait_boost = sg_cpu->sg_policy->policy->min;
		}
	} else if (sg_cpu->iowait_boost) {
		s64 delta_ns = time - sg_cpu->last_update;

		/* Clear iowait_boost if the CPU apprears to have been idle. */
		if (delta_ns > TICK_NSEC) {
			sg_cpu->iowait_boost = 0;
			sg_cpu->iowait_boost_pending = false;
		}
	}
}

static void pwr_iowait_boost(struct pwr_cpu *sg_cpu, unsigned long *util,
			       unsigned long *max)
{
	unsigned int boost_util, boost_max;

	if (!sg_cpu->iowait_boost)
		return;

	if (sg_cpu->iowait_boost_pending) {
		sg_cpu->iowait_boost_pending = false;
	} else {
		sg_cpu->iowait_boost >>= 1;
		if (sg_cpu->iowait_boost < sg_cpu->sg_policy->policy->min) {
			sg_cpu->iowait_boost = 0;
			return;
		}
	}

	boost_util = sg_cpu->iowait_boost;
	boost_max = sg_cpu->iowait_boost_max;

	if (*util * boost_max < *max * boost_util) {
		*util = boost_util;
		*max = boost_max;
	}
}

#ifdef CONFIG_NO_HZ_COMMON
static bool pwr_cpu_is_busy(struct pwr_cpu *sg_cpu)
{
	unsigned long idle_calls = tick_nohz_get_idle_calls_cpu(sg_cpu->cpu);
	bool ret = idle_calls == sg_cpu->saved_idle_calls;

	sg_cpu->saved_idle_calls = idle_calls;
	return ret;
}
#else
static inline bool pwr_cpu_is_busy(struct pwr_cpu *sg_cpu) { return false; }
#endif /* CONFIG_NO_HZ_COMMON */

#define NL_RATIO 75
#define DEFAULT_HISPEED_LOAD 75
static void pwr_walt_adjust(struct pwr_cpu *sg_cpu, unsigned long *util,
			      unsigned long *max)
{
	struct pwr_policy *sg_policy = sg_cpu->sg_policy;
	bool is_migration = sg_cpu->flags & SCHED_CPUFREQ_INTERCLUSTER_MIG;
	unsigned long nl = sg_cpu->walt_load.nl;
	unsigned long cpu_util = sg_cpu->util;
	bool is_hiload;

	if (unlikely(!sysctl_sched_use_walt_cpu_util))
		return;

	is_hiload = (cpu_util >= mult_frac(sg_policy->avg_cap,
					   sg_policy->tunables->hispeed_load,
					   100));

	if (is_hiload && !is_migration)
		*util = max(*util, sg_policy->hispeed_util);

	if (is_hiload && nl >= mult_frac(cpu_util, NL_RATIO, 100))
		*util = *max;

	if (sg_policy->tunables->pl)
		*util = max(*util, sg_cpu->walt_load.pl);
}

static void pwr_update_single(struct update_util_data *hook, u64 time,
				unsigned int flags)
{
	struct pwr_cpu *sg_cpu = container_of(hook, struct pwr_cpu, update_util);
	struct pwr_policy *sg_policy = sg_cpu->sg_policy;
	struct cpufreq_policy *policy = sg_policy->policy;
	unsigned long util, max, hs_util;
	unsigned int next_f;
	bool busy;

	if (flags & SCHED_CPUFREQ_PL)
		return;

	flags &= ~SCHED_CPUFREQ_RT_DL;
	pwr_set_iowait_boost(sg_cpu, time, flags);
	sg_cpu->last_update = time;

	if (!pwr_should_update_freq(sg_policy, time))
		return;

	busy = use_pelt() && pwr_cpu_is_busy(sg_cpu);

	raw_spin_lock(&sg_policy->update_lock);

	if (flags & SCHED_CPUFREQ_DL) {
		/* clear cache when it's bypassed */
		sg_policy->cached_raw_freq = 0;
		next_f = policy->cpuinfo.max_freq;
	} else {
		pwr_get_util(&util, &max, sg_cpu->cpu, time);
		if (sg_policy->max != max) {
			sg_policy->max = max;
			hs_util = freq_to_util(sg_policy,
					sg_policy->tunables->hispeed_freq);
			hs_util = mult_frac(hs_util, TARGET_LOAD, 100);
			sg_policy->hispeed_util = hs_util;
		}

		sg_cpu->util = util;
		sg_cpu->max = max;
		sg_cpu->flags = flags;

		pwr_calc_avg_cap(sg_policy, sg_cpu->walt_load.ws,
				   sg_policy->policy->cur);
		trace_sugov_util_update(sg_cpu->cpu, sg_cpu->util,
				sg_policy->avg_cap, max, sg_cpu->walt_load.nl,
				sg_cpu->walt_load.pl, flags);

		pwr_iowait_boost(sg_cpu, &util, &max);
		next_f = get_next_freq(sg_policy, util, max);
		/*
		 * Do not reduce the frequency if the CPU has not been idle
		 * recently, as the reduction is likely to be premature then.
		 */
		if (busy && next_f < sg_policy->next_freq &&
		    sg_policy->next_freq != UINT_MAX) {
			next_f = sg_policy->next_freq;

			/* Restore cached freq as next_freq has changed */
			sg_policy->cached_raw_freq = sg_policy->prev_cached_raw_freq;
		}
	}
	pwr_update_commit(sg_policy, time, next_f);
}

static unsigned int pwr_next_freq_shared(struct pwr_cpu *sg_cpu, u64 time)
{
	struct pwr_policy *sg_policy = sg_cpu->sg_policy;
	struct cpufreq_policy *policy = sg_policy->policy;
	unsigned long util = 0, max = 1;
	unsigned int j;

	for_each_cpu(j, policy->cpus) {
		struct pwr_cpu *j_sg_cpu = &per_cpu(pwr_cpu, j);
		unsigned long j_util, j_max;
		s64 delta_ns;

		/*
		 * If the CPU utilization was last updated before the previous
		 * frequency update and the time elapsed between the last update
		 * of the CPU utilization and the last frequency update is long
		 * enough, don't take the CPU into account as it probably is
		 * idle now (and clear iowait_boost for it).
		 */
		delta_ns = time - j_sg_cpu->last_update;
		if (delta_ns > stale_ns) {
			j_sg_cpu->iowait_boost = 0;
			j_sg_cpu->iowait_boost_pending = false;
			continue;
		}
		if (j_sg_cpu->flags & SCHED_CPUFREQ_DL) {
			/* clear cache when it's bypassed */
			sg_policy->cached_raw_freq = 0;
			return policy->cpuinfo.max_freq;
		}

		j_util = j_sg_cpu->util;
		j_max = j_sg_cpu->max;
		if (j_util * max > j_max * util) {
			util = j_util;
			max = j_max;
		}

		pwr_iowait_boost(j_sg_cpu, &util, &max);
	}

	return get_next_freq(sg_policy, util, max);
}

static void pwr_update_shared(struct update_util_data *hook, u64 time,
				unsigned int flags)
{
	struct pwr_cpu *sg_cpu = container_of(hook, struct pwr_cpu, update_util);
	struct pwr_policy *sg_policy = sg_cpu->sg_policy;
	unsigned long util, max;
	unsigned int next_f;

	if (flags & SCHED_CPUFREQ_PL)
		return;

	pwr_get_util(&util, &max, sg_cpu->cpu, time);

	flags &= ~SCHED_CPUFREQ_RT_DL;

	raw_spin_lock(&sg_policy->update_lock);

	sg_cpu->util = util;
	sg_cpu->max = max;
	sg_cpu->flags = flags;

	pwr_set_iowait_boost(sg_cpu, time, flags);
	sg_cpu->last_update = time;

	if (pwr_should_update_freq(sg_policy, time) &&
		!(flags & SCHED_CPUFREQ_CONTINUE)) {
		if (flags & SCHED_CPUFREQ_DL) {
			next_f = sg_policy->policy->cpuinfo.max_freq;
			/* clear cache when it's bypassed */
			sg_policy->cached_raw_freq = 0;
		} else {
			next_f = pwr_next_freq_shared(sg_cpu, time);
		}

		pwr_update_commit(sg_policy, time, next_f);
	}

	raw_spin_unlock(&sg_policy->update_lock);
}

static void pwr_work(struct kthread_work *work)
{
	struct pwr_policy *sg_policy = container_of(work, struct pwr_policy, work);

	mutex_lock(&sg_policy->work_lock);
	__cpufreq_driver_target(sg_policy->policy, sg_policy->next_freq,
				CPUFREQ_RELATION_L);
	mutex_unlock(&sg_policy->work_lock);

	if (use_pelt())
		sg_policy->work_in_progress = false;
}

static void pwr_irq_work(struct irq_work *irq_work)
{
	struct pwr_policy *sg_policy;

	sg_policy = container_of(irq_work, struct pwr_policy, irq_work);

	/*
	 * For RT and deadline tasks, the schedutil governor shoots the
	 * frequency to maximum. Special care must be taken to ensure that this
	 * kthread doesn't result in the same behavior.
	 *
	 * This is (mostly) guaranteed by the work_in_progress flag. The flag is
	 * updated only at the end of the pwr_work() function and before that
	 * the schedutil governor rejects all other frequency scaling requests.
	 *
	 * There is a very rare case though, where the RT thread yields right
	 * after the work_in_progress flag is cleared. The effects of that are
	 * neglected for now.
	 */
	kthread_queue_work(&sg_policy->worker, &sg_policy->work);
}

/************************** sysfs interface ************************/

static struct pwr_tunables *global_tunables;
static DEFINE_MUTEX(global_tunables_lock);

static inline struct pwr_tunables *to_pwr_tunables(struct gov_attr_set *attr_set)
{
	return container_of(attr_set, struct pwr_tunables, attr_set);
}

static DEFINE_MUTEX(min_rate_lock);

static void update_min_rate_limit_ns(struct pwr_policy *sg_policy)
{
	mutex_lock(&min_rate_lock);
	sg_policy->min_rate_limit_ns = min(sg_policy->up_rate_delay_ns,
					   sg_policy->down_rate_delay_ns);
	mutex_unlock(&min_rate_lock);
}

static ssize_t up_rate_limit_us_show(struct gov_attr_set *attr_set, char *buf)
{
	struct pwr_tunables *tunables = to_pwr_tunables(attr_set);

	return sprintf(buf, "%u\n", tunables->up_rate_limit_us);
}

static ssize_t down_rate_limit_us_show(struct gov_attr_set *attr_set, char *buf)
{
	struct pwr_tunables *tunables = to_pwr_tunables(attr_set);

	return sprintf(buf, "%u\n", tunables->down_rate_limit_us);
}

static ssize_t up_rate_limit_us_store(struct gov_attr_set *attr_set,
				      const char *buf, size_t count)
{
	struct pwr_tunables *tunables = to_pwr_tunables(attr_set);
	struct pwr_policy *sg_policy;
	unsigned int rate_limit_us;

	if (kstrtouint(buf, 10, &rate_limit_us))
		return -EINVAL;

	tunables->up_rate_limit_us = rate_limit_us;

	list_for_each_entry(sg_policy, &attr_set->policy_list, tunables_hook) {
		sg_policy->up_rate_delay_ns = rate_limit_us * NSEC_PER_USEC;
		update_min_rate_limit_ns(sg_policy);
	}

	return count;
}

static ssize_t down_rate_limit_us_store(struct gov_attr_set *attr_set,
					const char *buf, size_t count)
{
	struct pwr_tunables *tunables = to_pwr_tunables(attr_set);
	struct pwr_policy *sg_policy;
	unsigned int rate_limit_us;

	if (kstrtouint(buf, 10, &rate_limit_us))
		return -EINVAL;

	tunables->down_rate_limit_us = rate_limit_us;

	list_for_each_entry(sg_policy, &attr_set->policy_list, tunables_hook) {
		sg_policy->down_rate_delay_ns = rate_limit_us * NSEC_PER_USEC;
		update_min_rate_limit_ns(sg_policy);
	}

	return count;
}

static ssize_t iowait_boost_enable_show(struct gov_attr_set *attr_set,
                                        char *buf)
{
        struct pwr_tunables *tunables = to_pwr_tunables(attr_set);
        return snprintf(buf, PAGE_SIZE, "%u\n",
                        tunables->iowait_boost_enable);
}

static ssize_t iowait_boost_enable_store(struct gov_attr_set *attr_set,
                                         const char *buf, size_t count)
{
        struct pwr_tunables *tunables = to_pwr_tunables(attr_set);
        bool enable;
        if (kstrtobool(buf, &enable))
                return -EINVAL;

        tunables->iowait_boost_enable = enable;
        return count;
}

static struct governor_attr up_rate_limit_us = __ATTR_RW(up_rate_limit_us);
static struct governor_attr down_rate_limit_us = __ATTR_RW(down_rate_limit_us);
static struct governor_attr iowait_boost_enable =
	__ATTR_RW(iowait_boost_enable);

static struct attribute *pwr_attributes[] = {
	&up_rate_limit_us.attr,
	&down_rate_limit_us.attr,
	&iowait_boost_enable.attr,
	NULL
};

static void pwr_tunables_free(struct kobject *kobj)
{
	struct gov_attr_set *attr_set = container_of(kobj, struct gov_attr_set, kobj);

	kfree(to_pwr_tunables(attr_set));
}

static struct kobj_type pwr_tunables_ktype = {
	.default_attrs = pwr_attributes,
	.sysfs_ops = &governor_sysfs_ops,
	.release = &pwr_tunables_free,
};

/********************** cpufreq governor interface *********************/

static struct cpufreq_governor pwrutilx_gov;

static struct pwr_policy *pwr_policy_alloc(struct cpufreq_policy *policy)
{
	struct pwr_policy *sg_policy;

	sg_policy = kzalloc(sizeof(*sg_policy), GFP_KERNEL);
	if (!sg_policy)
		return NULL;

	sg_policy->policy = policy;
	raw_spin_lock_init(&sg_policy->update_lock);
	return sg_policy;
}

static void pwr_policy_free(struct pwr_policy *sg_policy)
{
	kfree(sg_policy);
}

static int pwr_kthread_create(struct pwr_policy *sg_policy)
{
	struct task_struct *thread;
	struct sched_param param = { .sched_priority = SUGOV_KTHREAD_PRIORITY };
	struct cpufreq_policy *policy = sg_policy->policy;
	int ret;

	/* kthread only required for slow path */
	if (policy->fast_switch_enabled)
		return 0;

	kthread_init_work(&sg_policy->work, pwr_work);
	kthread_init_worker(&sg_policy->worker);
	thread = kthread_create(kthread_worker_fn, &sg_policy->worker,
				"sugov:%d",
				cpumask_first(policy->related_cpus));
	if (IS_ERR(thread)) {
		pr_err("failed to create sugov thread: %ld\n", PTR_ERR(thread));
		return PTR_ERR(thread);
	}

	ret = sched_setscheduler_nocheck(thread, SCHED_FIFO, &param);
	if (ret) {
		kthread_stop(thread);
		pr_warn("%s: failed to set SCHED_FIFO\n", __func__);
		return ret;
	}

	sg_policy->thread = thread;

	/* Kthread is bound to all CPUs by default */
	if (!policy->dvfs_possible_from_any_cpu)
		kthread_bind_mask(thread, policy->related_cpus);

	init_irq_work(&sg_policy->irq_work, pwr_irq_work);
	mutex_init(&sg_policy->work_lock);

	wake_up_process(thread);

	return 0;
}

static void pwr_kthread_stop(struct pwr_policy *sg_policy)
{
	/* kthread only required for slow path */
	if (sg_policy->policy->fast_switch_enabled)
		return;

	kthread_flush_worker(&sg_policy->worker);
	kthread_stop(sg_policy->thread);
	mutex_destroy(&sg_policy->work_lock);
}

static struct pwr_tunables *pwr_tunables_alloc(struct pwr_policy *sg_policy)
{
	struct pwr_tunables *tunables;

	tunables = kzalloc(sizeof(*tunables), GFP_KERNEL);
	if (tunables) {
		gov_attr_set_init(&tunables->attr_set, &sg_policy->tunables_hook);
		if (!have_governor_per_policy())
			global_tunables = tunables;
	}
	return tunables;
}

static void pwr_tunables_save(struct cpufreq_policy *policy,
		struct pwr_tunables *tunables)
{
	int cpu;
	struct pwr_tunables *cached = per_cpu(cached_tunables, policy->cpu);

	if (!have_governor_per_policy())
		return;

	if (!cached) {
		cached = kzalloc(sizeof(*tunables), GFP_KERNEL);
		if (!cached)
			return;

		for_each_cpu(cpu, policy->related_cpus)
			per_cpu(cached_tunables, cpu) = cached;
	}

	cached->up_rate_limit_us = tunables->up_rate_limit_us;
	cached->down_rate_limit_us = tunables->down_rate_limit_us;
}

static void pwr_clear_global_tunables(void)
{
	if (!have_governor_per_policy())
		global_tunables = NULL;
}

static void pwr_tunables_restore(struct cpufreq_policy *policy)
{
	struct pwr_policy *sg_policy = policy->governor_data;
	struct pwr_tunables *tunables = sg_policy->tunables;
	struct pwr_tunables *cached = per_cpu(cached_tunables, policy->cpu);

	if (!cached)
		return;

	tunables->up_rate_limit_us = cached->up_rate_limit_us;
	tunables->down_rate_limit_us = cached->down_rate_limit_us;
	update_min_rate_limit_ns(sg_policy);
}

static int pwr_init(struct cpufreq_policy *policy)
{
	struct pwr_policy *sg_policy;
	struct pwr_tunables *tunables;
	int ret = 0;

	/* State should be equivalent to EXIT */
	if (policy->governor_data)
		return -EBUSY;

	cpufreq_enable_fast_switch(policy);

	sg_policy = pwr_policy_alloc(policy);
	if (!sg_policy) {
		ret = -ENOMEM;
		goto disable_fast_switch;
	}

	ret = pwr_kthread_create(sg_policy);
	if (ret)
		goto free_sg_policy;

	mutex_lock(&global_tunables_lock);

	if (global_tunables) {
		if (WARN_ON(have_governor_per_policy())) {
			ret = -EINVAL;
			goto stop_kthread;
		}
		policy->governor_data = sg_policy;
		sg_policy->tunables = global_tunables;

		gov_attr_set_get(&global_tunables->attr_set, &sg_policy->tunables_hook);
		goto out;
	}

	tunables = pwr_tunables_alloc(sg_policy);
	if (!tunables) {
		ret = -ENOMEM;
		goto stop_kthread;
	}

	tunables->up_rate_limit_us =
				cpufreq_policy_transition_delay_us(policy);
	tunables->down_rate_limit_us =
				cpufreq_policy_transition_delay_us(policy);
	tunables->iowait_boost_enable = false;
	tunables->hispeed_load = DEFAULT_HISPEED_LOAD;
	tunables->pl = true;

	policy->governor_data = sg_policy;
	sg_policy->tunables = tunables;
	stale_ns = sched_ravg_window + (sched_ravg_window >> 3);

	pwr_tunables_restore(policy);

	ret = kobject_init_and_add(&tunables->attr_set.kobj, &pwr_tunables_ktype,
				   get_governor_parent_kobj(policy), "%s",
				   pwrutilx_gov.name);
	if (ret)
		goto fail;

out:
	mutex_unlock(&global_tunables_lock);
	return 0;

fail:
	kobject_put(&tunables->attr_set.kobj);
	policy->governor_data = NULL;
	pwr_clear_global_tunables();

stop_kthread:
	pwr_kthread_stop(sg_policy);
	mutex_unlock(&global_tunables_lock);

free_sg_policy:
	pwr_policy_free(sg_policy);

disable_fast_switch:
	cpufreq_disable_fast_switch(policy);

	pr_err("initialization failed (error %d)\n", ret);
	return ret;
}

static void pwr_exit(struct cpufreq_policy *policy)
{
	struct pwr_policy *sg_policy = policy->governor_data;
	struct pwr_tunables *tunables = sg_policy->tunables;
	unsigned int count;

	mutex_lock(&global_tunables_lock);

	count = gov_attr_set_put(&tunables->attr_set, &sg_policy->tunables_hook);
	policy->governor_data = NULL;
	if (!count) {
		pwr_tunables_save(policy, tunables);
		pwr_clear_global_tunables();
	}

	mutex_unlock(&global_tunables_lock);

	pwr_kthread_stop(sg_policy);
	pwr_policy_free(sg_policy);
	cpufreq_disable_fast_switch(policy);
}

static int pwr_start(struct cpufreq_policy *policy)
{
	struct pwr_policy *sg_policy = policy->governor_data;
	unsigned int cpu;

	sg_policy->up_rate_delay_ns =
		sg_policy->tunables->up_rate_limit_us * NSEC_PER_USEC;
	sg_policy->down_rate_delay_ns =
		sg_policy->tunables->down_rate_limit_us * NSEC_PER_USEC;
	sg_policy->last_freq_update_time = 0;
	sg_policy->next_freq = UINT_MAX;
	sg_policy->work_in_progress = false;
	sg_policy->need_freq_update = false;
	sg_policy->cached_raw_freq = 0;
	sg_policy->prev_cached_raw_freq = 0;

	for_each_cpu(cpu, policy->cpus) {
		struct pwr_cpu *sg_cpu = &per_cpu(pwr_cpu, cpu);

		memset(sg_cpu, 0, sizeof(*sg_cpu));
		sg_cpu->cpu = cpu;
		sg_cpu->sg_policy = sg_policy;
		sg_cpu->flags = SCHED_CPUFREQ_DL;
		sg_cpu->iowait_boost_max = policy->cpuinfo.max_freq;
	}

	for_each_cpu(cpu, policy->cpus) {
		struct pwr_cpu *sg_cpu = &per_cpu(pwr_cpu, cpu);

		cpufreq_add_update_util_hook(cpu, &sg_cpu->update_util,
					     policy_is_shared(policy) ?
							pwr_update_shared :
							pwr_update_single);
	}
	return 0;
}

static void pwr_stop(struct cpufreq_policy *policy)
{
	struct pwr_policy *sg_policy = policy->governor_data;
	unsigned int cpu;

	for_each_cpu(cpu, policy->cpus)
		cpufreq_remove_update_util_hook(cpu);

	synchronize_sched();

	if (!policy->fast_switch_enabled) {
		irq_work_sync(&sg_policy->irq_work);
		kthread_cancel_work_sync(&sg_policy->work);
	}
}

static void pwr_limits(struct cpufreq_policy *policy)
{
	struct pwr_policy *sg_policy = policy->governor_data;
	unsigned long flags;

	if (!policy->fast_switch_enabled) {
		mutex_lock(&sg_policy->work_lock);
		cpufreq_policy_apply_limits(policy);
		mutex_unlock(&sg_policy->work_lock);
	} else {
		raw_spin_lock_irqsave(&sg_policy->update_lock, flags);
		pwr_track_cycles(sg_policy, sg_policy->policy->cur,
				   ktime_get_ns());
		cpufreq_policy_apply_limits_fast(policy);
		raw_spin_unlock_irqrestore(&sg_policy->update_lock, flags);
	}

	sg_policy->need_freq_update = true;
}

static struct cpufreq_governor pwrutilx_gov = {
	.name = "pwrutilx",
	.owner = THIS_MODULE,
	.dynamic_switching = true,
	.init = pwr_init,
	.exit = pwr_exit,
	.start = pwr_start,
	.stop = pwr_stop,
	.limits = pwr_limits,
};

static int __init pwr_register(void)
{
	return cpufreq_register_governor(&pwrutilx_gov);
}
core_initcall(pwr_register);
