/*
 *  drivers/cpufreq/cpufreq_smartmax.c
 *
 *  SmartMax governor - asymmetric up/down ramps around an ideal frequency.
 *
 *  Behavior:
 *   - load above up_threshold: ramp up quickly; jump straight to
 *     ideal_freq first when below it, then step up by ramp_up_step.
 *   - load below down_threshold: step down by ramp_down_step.
 *   - otherwise: hold the current frequency.
 *
 *  Written against the 4.14 dbs governor framework, modeled on
 *  cpufreq_conservative.c.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#include <linux/slab.h>
#include "cpufreq_governor.h"

struct sm_policy_dbs_info {
	struct policy_dbs_info policy_dbs;
	unsigned int requested_freq;
};

static inline struct sm_policy_dbs_info *to_sm_info(struct policy_dbs_info *policy_dbs)
{
	return container_of(policy_dbs, struct sm_policy_dbs_info, policy_dbs);
}

struct sm_dbs_tuners {
	unsigned int down_threshold;
	unsigned int ideal_freq;
	unsigned int ramp_up_step;
	unsigned int ramp_down_step;
};

/* SmartMax governor macros */
#define DEF_FREQUENCY_UP_THRESHOLD		(75)
#define DEF_FREQUENCY_DOWN_THRESHOLD		(30)
#define DEF_IDEAL_FREQ				(0)
#define DEF_RAMP_UP_STEP			(15)
#define DEF_RAMP_DOWN_STEP			(5)

static unsigned int sm_calc_step(struct sm_dbs_tuners *sm_tuners,
				 struct cpufreq_policy *policy,
				 unsigned int step_pct)
{
	unsigned int step = (step_pct * policy->max) / 100;

	/* max freq cannot be less than 100. But who knows... */
	if (unlikely(step == 0))
		step = 1;

	return step;
}

/*
 * Every sampling_rate, we check the load:
 *  - above up_threshold: ramp up (via ideal_freq first, then ramp_up_step)
 *  - below down_threshold: ramp down by ramp_down_step
 *  - in between: hold frequency
 */
static unsigned int sm_dbs_update(struct cpufreq_policy *policy)
{
	struct policy_dbs_info *policy_dbs = policy->governor_data;
	struct sm_policy_dbs_info *dbs_info = to_sm_info(policy_dbs);
	unsigned int requested_freq = dbs_info->requested_freq;
	struct dbs_data *dbs_data = policy_dbs->dbs_data;
	struct sm_dbs_tuners *sm_tuners = dbs_data->tuners;
	unsigned int load = dbs_update(policy);
	unsigned int step;

	/*
	 * If requested_freq is out of range, it is likely that the limits
	 * changed in the meantime, so fall back to current frequency in that
	 * case.
	 */
	if (requested_freq > policy->max || requested_freq < policy->min) {
		requested_freq = policy->cur;
		dbs_info->requested_freq = requested_freq;
	}

	/* Check for frequency increase */
	if (load > dbs_data->up_threshold) {
		/* if we are already at full speed then break out early */
		if (requested_freq == policy->max)
			goto out;

		/* jump to the ideal frequency first when below it */
		if (sm_tuners->ideal_freq > policy->min &&
		    sm_tuners->ideal_freq <= policy->max &&
		    requested_freq < sm_tuners->ideal_freq) {
			requested_freq = sm_tuners->ideal_freq;
		} else {
			step = sm_calc_step(sm_tuners, policy,
					    sm_tuners->ramp_up_step);
			requested_freq += step;
			if (requested_freq > policy->max)
				requested_freq = policy->max;
		}

		__cpufreq_driver_target(policy, requested_freq, CPUFREQ_RELATION_H);
		dbs_info->requested_freq = requested_freq;
		goto out;
	}

	/* Check for frequency decrease */
	if (load < sm_tuners->down_threshold) {
		/*
		 * if we cannot reduce the frequency anymore, break out early
		 */
		if (requested_freq == policy->min)
			goto out;

		step = sm_calc_step(sm_tuners, policy,
				    sm_tuners->ramp_down_step);
		if (requested_freq > step)
			requested_freq -= step;
		else
			requested_freq = policy->min;

		__cpufreq_driver_target(policy, requested_freq, CPUFREQ_RELATION_L);
		dbs_info->requested_freq = requested_freq;
	}

 out:
	return dbs_data->sampling_rate;
}

/************************** sysfs interface ************************/

static ssize_t store_up_threshold(struct gov_attr_set *attr_set,
				  const char *buf, size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	struct sm_dbs_tuners *sm_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	if (ret != 1 || input > 100 || input <= sm_tuners->down_threshold)
		return -EINVAL;

	dbs_data->up_threshold = input;
	return count;
}

static ssize_t store_down_threshold(struct gov_attr_set *attr_set,
				    const char *buf, size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	struct sm_dbs_tuners *sm_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	/* cannot be lower than 1 otherwise freq will not fall */
	if (ret != 1 || input < 1 || input > 100 ||
			input >= dbs_data->up_threshold)
		return -EINVAL;

	sm_tuners->down_threshold = input;
	return count;
}

static ssize_t store_ignore_nice_load(struct gov_attr_set *attr_set,
				      const char *buf, size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1)
		return -EINVAL;

	if (input > 1)
		input = 1;

	if (input == dbs_data->ignore_nice_load) /* nothing to do */
		return count;

	dbs_data->ignore_nice_load = input;

	/* we need to re-evaluate prev_cpu_idle */
	gov_update_cpu_data(dbs_data);

	return count;
}

static ssize_t store_ideal_freq(struct gov_attr_set *attr_set, const char *buf,
				size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	struct sm_dbs_tuners *sm_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	if (ret != 1)
		return -EINVAL;

	sm_tuners->ideal_freq = input;
	return count;
}

static ssize_t store_ramp_up_step(struct gov_attr_set *attr_set,
				  const char *buf, size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	struct sm_dbs_tuners *sm_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	if (ret != 1 || input < 1)
		return -EINVAL;

	if (input > 100)
		input = 100;

	sm_tuners->ramp_up_step = input;
	return count;
}

static ssize_t store_ramp_down_step(struct gov_attr_set *attr_set,
				    const char *buf, size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	struct sm_dbs_tuners *sm_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	if (ret != 1 || input < 1)
		return -EINVAL;

	if (input > 100)
		input = 100;

	sm_tuners->ramp_down_step = input;
	return count;
}

gov_show_one_common(sampling_rate);
gov_show_one_common(up_threshold);
gov_show_one_common(ignore_nice_load);
gov_show_one(sm, down_threshold);
gov_show_one(sm, ideal_freq);
gov_show_one(sm, ramp_up_step);
gov_show_one(sm, ramp_down_step);

gov_attr_rw(sampling_rate);
gov_attr_rw(up_threshold);
gov_attr_rw(ignore_nice_load);
gov_attr_rw(down_threshold);
gov_attr_rw(ideal_freq);
gov_attr_rw(ramp_up_step);
gov_attr_rw(ramp_down_step);

static struct attribute *sm_attributes[] = {
	&sampling_rate.attr,
	&up_threshold.attr,
	&down_threshold.attr,
	&ignore_nice_load.attr,
	&ideal_freq.attr,
	&ramp_up_step.attr,
	&ramp_down_step.attr,
	NULL
};

/************************** sysfs end ************************/

static struct policy_dbs_info *sm_alloc(void)
{
	struct sm_policy_dbs_info *dbs_info;

	dbs_info = kzalloc(sizeof(*dbs_info), GFP_KERNEL);
	return dbs_info ? &dbs_info->policy_dbs : NULL;
}

static void sm_free(struct policy_dbs_info *policy_dbs)
{
	kfree(to_sm_info(policy_dbs));
}

static int sm_init(struct dbs_data *dbs_data)
{
	struct sm_dbs_tuners *tuners;

	tuners = kzalloc(sizeof(*tuners), GFP_KERNEL);
	if (!tuners)
		return -ENOMEM;

	tuners->down_threshold = DEF_FREQUENCY_DOWN_THRESHOLD;
	tuners->ideal_freq = DEF_IDEAL_FREQ;
	tuners->ramp_up_step = DEF_RAMP_UP_STEP;
	tuners->ramp_down_step = DEF_RAMP_DOWN_STEP;
	dbs_data->up_threshold = DEF_FREQUENCY_UP_THRESHOLD;
	dbs_data->ignore_nice_load = 0;
	dbs_data->tuners = tuners;

	return 0;
}

static void sm_exit(struct dbs_data *dbs_data)
{
	kfree(dbs_data->tuners);
}

static void sm_start(struct cpufreq_policy *policy)
{
	struct sm_policy_dbs_info *dbs_info = to_sm_info(policy->governor_data);

	dbs_info->requested_freq = policy->cur;
}

static struct dbs_governor sm_governor = {
	.gov = CPUFREQ_DBS_GOVERNOR_INITIALIZER("smartmax"),
	.kobj_type = { .default_attrs = sm_attributes },
	.gov_dbs_update = sm_dbs_update,
	.alloc = sm_alloc,
	.free = sm_free,
	.init = sm_init,
	.exit = sm_exit,
	.start = sm_start,
};

#define CPU_FREQ_GOV_SMARTMAX	(&sm_governor.gov)

static int __init cpufreq_gov_dbs_init(void)
{
	return cpufreq_register_governor(CPU_FREQ_GOV_SMARTMAX);
}

static void __exit cpufreq_gov_dbs_exit(void)
{
	cpufreq_unregister_governor(CPU_FREQ_GOV_SMARTMAX);
}

MODULE_AUTHOR("SmartMax governor");
MODULE_DESCRIPTION("'cpufreq_smartmax' - asymmetric ramps around an ideal frequency");
MODULE_LICENSE("GPL");

module_init(cpufreq_gov_dbs_init);
module_exit(cpufreq_gov_dbs_exit);
