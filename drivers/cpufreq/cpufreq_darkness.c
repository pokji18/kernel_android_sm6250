/*
 *  drivers/cpufreq/cpufreq_darkness.c
 *
 *  Darkness governor - ondemand-style fast ramp-up with gradual ramp-down
 *  around an ideal frequency.
 *
 *  Behavior:
 *   - load above up_threshold: jump straight to max (low latency).
 *   - load below (up_threshold - down_differential): step down gradually.
 *   - in between: drift toward ideal_freq when it is configured.
 *
 *  Written against the 4.14 dbs governor framework, modeled on
 *  cpufreq_conservative.c / cpufreq_ondemand.c.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#include <linux/slab.h>
#include "cpufreq_governor.h"

struct dk_policy_dbs_info {
	struct policy_dbs_info policy_dbs;
	unsigned int requested_freq;
};

static inline struct dk_policy_dbs_info *to_dk_info(struct policy_dbs_info *policy_dbs)
{
	return container_of(policy_dbs, struct dk_policy_dbs_info, policy_dbs);
}

struct dk_dbs_tuners {
	unsigned int down_differential;
	unsigned int ideal_freq;
	unsigned int freq_step;
};

/* Darkness governor macros */
#define DEF_FREQUENCY_UP_THRESHOLD		(75)
#define DEF_DOWN_DIFFERENTIAL			(15)
#define DEF_IDEAL_FREQ				(0)
#define DEF_FREQUENCY_STEP			(10)

static inline unsigned int get_freq_step(struct dk_dbs_tuners *dk_tuners,
					 struct cpufreq_policy *policy)
{
	unsigned int freq_step = (dk_tuners->freq_step * policy->max) / 100;

	/* max freq cannot be less than 100. But who knows... */
	if (unlikely(freq_step == 0))
		freq_step = DEF_FREQUENCY_STEP;

	return freq_step;
}

/*
 * Every sampling_rate, we check the load:
 *  - above up_threshold: jump to max for minimum latency.
 *  - below (up_threshold - down_differential): step down gradually.
 *  - in between: drift toward ideal_freq when configured.
 */
static unsigned int dk_dbs_update(struct cpufreq_policy *policy)
{
	struct policy_dbs_info *policy_dbs = policy->governor_data;
	struct dk_policy_dbs_info *dbs_info = to_dk_info(policy_dbs);
	unsigned int requested_freq = dbs_info->requested_freq;
	struct dbs_data *dbs_data = policy_dbs->dbs_data;
	struct dk_dbs_tuners *dk_tuners = dbs_data->tuners;
	unsigned int load = dbs_update(policy);
	unsigned int freq_step;

	/*
	 * If requested_freq is out of range, it is likely that the limits
	 * changed in the meantime, so fall back to current frequency in that
	 * case.
	 */
	if (requested_freq > policy->max || requested_freq < policy->min) {
		requested_freq = policy->cur;
		dbs_info->requested_freq = requested_freq;
	}

	freq_step = get_freq_step(dk_tuners, policy);

	/* Check for frequency increase: jump straight to max */
	if (load > dbs_data->up_threshold) {
		/* if we are already at full speed then break out early */
		if (requested_freq == policy->max)
			goto out;

		requested_freq = policy->max;

		__cpufreq_driver_target(policy, requested_freq, CPUFREQ_RELATION_H);
		dbs_info->requested_freq = requested_freq;
		goto out;
	}

	/* Check for frequency decrease */
	if (load < (dbs_data->up_threshold - dk_tuners->down_differential)) {
		/*
		 * if we cannot reduce the frequency anymore, break out early
		 */
		if (requested_freq == policy->min)
			goto out;

		if (requested_freq > freq_step)
			requested_freq -= freq_step;
		else
			requested_freq = policy->min;

		__cpufreq_driver_target(policy, requested_freq, CPUFREQ_RELATION_L);
		dbs_info->requested_freq = requested_freq;
		goto out;
	}

	/* Moderate load: drift toward the ideal frequency when configured */
	if (dk_tuners->ideal_freq > policy->min &&
	    dk_tuners->ideal_freq <= policy->max &&
	    requested_freq < dk_tuners->ideal_freq) {
		requested_freq = dk_tuners->ideal_freq;

		__cpufreq_driver_target(policy, requested_freq, CPUFREQ_RELATION_H);
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
	struct dk_dbs_tuners *dk_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	if (ret != 1 || input > 100 ||
	    input <= dk_tuners->down_differential)
		return -EINVAL;

	dbs_data->up_threshold = input;
	return count;
}

static ssize_t store_down_differential(struct gov_attr_set *attr_set,
				       const char *buf, size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	struct dk_dbs_tuners *dk_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	if (ret != 1 || input < 1 || input > 100 ||
			input >= dbs_data->up_threshold)
		return -EINVAL;

	dk_tuners->down_differential = input;
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
	struct dk_dbs_tuners *dk_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	if (ret != 1)
		return -EINVAL;

	dk_tuners->ideal_freq = input;
	return count;
}

static ssize_t store_freq_step(struct gov_attr_set *attr_set, const char *buf,
			       size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	struct dk_dbs_tuners *dk_tuners = dbs_data->tuners;
	unsigned int input;
	int ret;
	ret = sscanf(buf, "%u", &input);

	if (ret != 1)
		return -EINVAL;

	if (input > 100)
		input = 100;

	/*
	 * no need to test here if freq_step is zero as the user might actually
	 * want this, they would be crazy though :)
	 */
	dk_tuners->freq_step = input;
	return count;
}

gov_show_one_common(sampling_rate);
gov_show_one_common(up_threshold);
gov_show_one_common(ignore_nice_load);
gov_show_one(dk, down_differential);
gov_show_one(dk, ideal_freq);
gov_show_one(dk, freq_step);

gov_attr_rw(sampling_rate);
gov_attr_rw(up_threshold);
gov_attr_rw(ignore_nice_load);
gov_attr_rw(down_differential);
gov_attr_rw(ideal_freq);
gov_attr_rw(freq_step);

static struct attribute *dk_attributes[] = {
	&sampling_rate.attr,
	&up_threshold.attr,
	&down_differential.attr,
	&ignore_nice_load.attr,
	&ideal_freq.attr,
	&freq_step.attr,
	NULL
};

/************************** sysfs end ************************/

static struct policy_dbs_info *dk_alloc(void)
{
	struct dk_policy_dbs_info *dbs_info;

	dbs_info = kzalloc(sizeof(*dbs_info), GFP_KERNEL);
	return dbs_info ? &dbs_info->policy_dbs : NULL;
}

static void dk_free(struct policy_dbs_info *policy_dbs)
{
	kfree(to_dk_info(policy_dbs));
}

static int dk_init(struct dbs_data *dbs_data)
{
	struct dk_dbs_tuners *tuners;

	tuners = kzalloc(sizeof(*tuners), GFP_KERNEL);
	if (!tuners)
		return -ENOMEM;

	tuners->down_differential = DEF_DOWN_DIFFERENTIAL;
	tuners->ideal_freq = DEF_IDEAL_FREQ;
	tuners->freq_step = DEF_FREQUENCY_STEP;
	dbs_data->up_threshold = DEF_FREQUENCY_UP_THRESHOLD;
	dbs_data->ignore_nice_load = 0;
	dbs_data->tuners = tuners;

	return 0;
}

static void dk_exit(struct dbs_data *dbs_data)
{
	kfree(dbs_data->tuners);
}

static void dk_start(struct cpufreq_policy *policy)
{
	struct dk_policy_dbs_info *dbs_info = to_dk_info(policy->governor_data);

	dbs_info->requested_freq = policy->cur;
}

static struct dbs_governor dk_governor = {
	.gov = CPUFREQ_DBS_GOVERNOR_INITIALIZER("darkness"),
	.kobj_type = { .default_attrs = dk_attributes },
	.gov_dbs_update = dk_dbs_update,
	.alloc = dk_alloc,
	.free = dk_free,
	.init = dk_init,
	.exit = dk_exit,
	.start = dk_start,
};

#define CPU_FREQ_GOV_DARKNESS	(&dk_governor.gov)

static int __init cpufreq_gov_dbs_init(void)
{
	return cpufreq_register_governor(CPU_FREQ_GOV_DARKNESS);
}

static void __exit cpufreq_gov_dbs_exit(void)
{
	cpufreq_unregister_governor(CPU_FREQ_GOV_DARKNESS);
}

MODULE_AUTHOR("Darkness governor");
MODULE_DESCRIPTION("'cpufreq_darkness' - fast ramp-up with gradual ramp-down");
MODULE_LICENSE("GPL");

module_init(cpufreq_gov_dbs_init);
module_exit(cpufreq_gov_dbs_exit);
