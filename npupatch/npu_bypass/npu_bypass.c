/*
 * npu_bypass.ko v7 - Bypass NPU container namespace isolation
 *
 * Uses kretprobe to selectively bypass ascend_uda isolation checks.
 *
 * Key design decisions:
 *   - Does NOT hook uda_cur_is_admin (admin ns_id causes array OOB)
 *   - Does NOT hook devdrv_manager_container_is_in_container
 *   - Uses device cgroup scan to resolve devid → udevid mapping
 *     when ns_node lookup fails (avoids broken uda_setup_ns_node
 *     which has a loop range bug for high-numbered devices)
 *
 * Usage:
 *   insmod npu_bypass.ko [davinci_major=235]
 *   rmmod npu_bypass
 */

#include <linux/kallsyms.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/module.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("nvshare");
MODULE_DESCRIPTION("Bypass NPU container isolation for cross-pod sharing");

static int davinci_major = 235;
module_param(davinci_major, int, 0444);
MODULE_PARM_DESC(davinci_major, "Major number of /dev/davinci* devices");

/* Max physical devices to scan */
#define MAX_PHY_DEVS 64

typedef int (*devcgroup_check_fn_t)(short, u32, u32, short);
static devcgroup_check_fn_t devcgroup_check_fn;
typedef int (*container_check_fn_t)(void);
static container_check_fn_t container_check_fn;

#define DEVCG_DEV_CHAR 2
#define DEVCG_ACC_READ 2
#define DEVCG_ACC_WRITE 4

static bool dev_in_cgroup(u32 udevid) {
  int ret_read, ret_write;
  if (!devcgroup_check_fn)
    return false;
  ret_read = devcgroup_check_fn(DEVCG_DEV_CHAR, davinci_major, udevid,
                                DEVCG_ACC_READ);
  ret_write = devcgroup_check_fn(DEVCG_DEV_CHAR, davinci_major, udevid,
                                 DEVCG_ACC_WRITE);
  return (ret_read == 0) || (ret_write == 0);
}

static bool current_in_container(void) {
  if (!container_check_fn)
    return false;
  return container_check_fn() == 1;
}

/*
 * Find the N-th device (0-indexed) in the current process's cgroup.
 * This replicates what uda_init_ns_node_dev does with the admin loop,
 * but without the phy_dev_num range limitation.
 *
 * Returns: physical udevid, or -1 if not found.
 */
static int cgroup_find_nth_device(u32 n) {
  u32 udevid, count = 0;
  for (udevid = 0; udevid < MAX_PHY_DEVS; udevid++) {
    if (dev_in_cgroup(udevid)) {
      if (count == n)
        return (int)udevid;
      count++;
    }
  }
  return -1;
}

/* ============================================================
 * Hook 1: uda_can_access_udevid → CGROUP-AWARE
 *
 * If original returns false → check device cgroup.
 * Only overrides for devices assigned to this pod.
 * ============================================================ */
struct access_check_data {
  unsigned long udevid;
};

static int entry_handler_access(struct kretprobe_instance *ri,
                                struct pt_regs *regs) {
  struct access_check_data *data = (struct access_check_data *)ri->data;
  data->udevid = regs->regs[0];
  return 0;
}

static int ret_handler_access(struct kretprobe_instance *ri,
                              struct pt_regs *regs) {
  int ret = (int)regs->regs[0];
  if (!ret) {
    struct access_check_data *data = (struct access_check_data *)ri->data;
    if (dev_in_cgroup((u32)data->udevid))
      regs->regs[0] = 1;
  }
  return 0;
}

static struct kretprobe krp_can_access = {
    .entry_handler = entry_handler_access,
    .handler = ret_handler_access,
    .data_size = sizeof(struct access_check_data),
    .maxactive = 64,
    .kp.symbol_name = "uda_can_access_udevid",
};

/* ============================================================
 * Hook 1b: uda_task_can_access_udevid → CGROUP-AWARE
 *
 * In some driver builds, uda_can_access_udevid can be inlined in
 * the same translation unit. Hook the deeper helper to ensure
 * ns_node setup path is covered.
 * ============================================================ */
struct task_access_data {
  unsigned long task_ptr;
  unsigned long udevid;
};

static int entry_handler_task_access(struct kretprobe_instance *ri,
                                     struct pt_regs *regs) {
  struct task_access_data *data = (struct task_access_data *)ri->data;
  data->task_ptr = regs->regs[0];
  data->udevid = regs->regs[1];
  return 0;
}

static int ret_handler_task_access(struct kretprobe_instance *ri,
                                   struct pt_regs *regs) {
  int ret = (int)regs->regs[0];
  if (!ret) {
    struct task_access_data *data = (struct task_access_data *)ri->data;
    if ((struct task_struct *)data->task_ptr == current &&
        dev_in_cgroup((u32)data->udevid))
      regs->regs[0] = 1;
  }
  return 0;
}

static struct kretprobe krp_task_access = {
    .entry_handler = entry_handler_task_access,
    .handler = ret_handler_task_access,
    .data_size = sizeof(struct task_access_data),
    .maxactive = 64,
    .kp.symbol_name = "uda_task_can_access_udevid",
};

/* ============================================================
 * Hook 2: uda_proc_can_access_udevid → CGROUP-AWARE
 * ============================================================ */
struct proc_access_data {
  unsigned long udevid;
};

static int entry_handler_proc_access(struct kretprobe_instance *ri,
                                     struct pt_regs *regs) {
  struct proc_access_data *data = (struct proc_access_data *)ri->data;
  data->udevid = regs->regs[1];
  return 0;
}

static int ret_handler_proc_access(struct kretprobe_instance *ri,
                                   struct pt_regs *regs) {
  int ret = (int)regs->regs[0];
  if (!ret) {
    struct proc_access_data *data = (struct proc_access_data *)ri->data;
    if (dev_in_cgroup((u32)data->udevid))
      regs->regs[0] = 1;
  }
  return 0;
}

static struct kretprobe krp_proc_can_access = {
    .entry_handler = entry_handler_proc_access,
    .handler = ret_handler_proc_access,
    .data_size = sizeof(struct proc_access_data),
    .maxactive = 64,
    .kp.symbol_name = "uda_proc_can_access_udevid",
};

/* ============================================================
 * Hook 3: uda_occupy_dev_by_ns → allow assigned device in container
 * ============================================================ */
struct occupy_data {
  unsigned long udevid;
};

static int entry_handler_occupy(struct kretprobe_instance *ri,
                                struct pt_regs *regs) {
  struct occupy_data *data = (struct occupy_data *)ri->data;
  data->udevid = regs->regs[0];
  return 0;
}

static int ret_handler_occupy(struct kretprobe_instance *ri,
                              struct pt_regs *regs) {
  int ret = (int)regs->regs[0];

  if (ret == -EBUSY) {
    /*
     * Keep original namespace binding logic, only suppress "occupied" failure.
     * This matches the proven behavior from the first working version.
     */
    regs->regs[0] = 0;
  }
  return 0;
}

static struct kretprobe krp_occupy = {
    .entry_handler = entry_handler_occupy,
    .handler = ret_handler_occupy,
    .data_size = sizeof(struct occupy_data),
    .maxactive = 64,
    .kp.symbol_name = "uda_occupy_dev_by_ns",
};

/* ============================================================
 * Hook 4: uda_devcgroup_permission_allow → tolerate busy-open
 *
 * In host cgroup path, the original helper opens /dev/davinciX with O_WRONLY.
 * When another namespace already occupies the device, that open can return
 * -EBUSY and the helper reports "no permission", causing node_dev_num=0.
 *
 * For nvshare we only need to bypass this false-negative permission result.
 * ============================================================ */
static int ret_handler_devcgroup_allow(struct kretprobe_instance *ri,
                                       struct pt_regs *regs) {
  if ((int)regs->regs[0] == 0)
    regs->regs[0] = 1;
  return 0;
}

static struct kretprobe krp_devcgroup_allow = {
    .handler = ret_handler_devcgroup_allow,
    .maxactive = 64,
    .kp.symbol_name = "uda_devcgroup_permission_allow",
};

/* ============================================================
 * Hook 5: uda_ns_node_devid_to_udevid → CGROUP SCAN FALLBACK
 *
 * This is the critical hook. When ns_node lookup fails (-EAGAIN):
 *
 * The driver's uda_setup_ns_node has a design limitation:
 * uda_init_ns_node_dev iterates udevid 0..phy_dev_num, where
 * phy_dev_num is often 1 (single device in cgroup). But if the
 * physical device ID > 0 (e.g., udevid=4), the loop never
 * reaches it. Using admin path to extend the range causes
 * admin ns_id allocation which corrupts ns_ids[] arrays.
 *
 * Solution: bypass uda_setup_ns_node entirely. Scan the device
 * cgroup to find the N-th physical device for logical devid N.
 * This is the same mapping that a correctly working ns_node
 * would provide.
 * ============================================================ */
struct devid_to_udevid_data {
  unsigned long devid;
  unsigned long udevid_ptr;
};

static int entry_handler_devid(struct kretprobe_instance *ri,
                               struct pt_regs *regs) {
  struct devid_to_udevid_data *data = (struct devid_to_udevid_data *)ri->data;
  data->devid = regs->regs[0];
  data->udevid_ptr = regs->regs[1];
  return 0;
}

static int ret_handler_devid(struct kretprobe_instance *ri,
                             struct pt_regs *regs) {
  int ret = (int)regs->regs[0];
  bool force_map = current_in_container();

  if (ret != 0 || force_map) {
    struct devid_to_udevid_data *data = (struct devid_to_udevid_data *)ri->data;
    u32 devid = (u32)data->devid;
    u32 *udevid_ptr = (u32 *)data->udevid_ptr;
    int phy_devid;

    /*
     * Scan cgroup to find the devid-th physical device.
     * E.g., if cgroup has device 4, and devid=0:
     *   cgroup_find_nth_device(0) → 4
     *   So devid 0 → udevid 4 ✓
     */
    phy_devid = cgroup_find_nth_device(devid);
    if (phy_devid >= 0 && udevid_ptr) {
      *udevid_ptr = (u32)phy_devid;
      regs->regs[0] = 0;
    }
  }
  return 0;
}

static struct kretprobe krp_devid_to_udevid = {
    .entry_handler = entry_handler_devid,
    .handler = ret_handler_devid,
    .data_size = sizeof(struct devid_to_udevid_data),
    .maxactive = 64,
    .kp.symbol_name = "uda_ns_node_devid_to_udevid",
};

/* ============================================================
 * Hook 6: devdrv_manager_container_logical_id_to_physical_id
 *         → cgroup scan fallback on failure
 * ============================================================ */
struct logical_to_phy_data {
  unsigned long logical_dev_id;
  unsigned long physical_dev_id_ptr;
  unsigned long vfid_ptr;
};

static int entry_handler_l2p(struct kretprobe_instance *ri,
                             struct pt_regs *regs) {
  struct logical_to_phy_data *data = (struct logical_to_phy_data *)ri->data;
  data->logical_dev_id = regs->regs[0];
  data->physical_dev_id_ptr = regs->regs[1];
  data->vfid_ptr = regs->regs[2];
  return 0;
}

static int ret_handler_l2p(struct kretprobe_instance *ri,
                           struct pt_regs *regs) {
  int ret = (int)regs->regs[0];
  bool force_map = current_in_container();
  if (ret != 0 || force_map) {
    struct logical_to_phy_data *data = (struct logical_to_phy_data *)ri->data;
    u32 logical = (u32)data->logical_dev_id;
    u32 *phy_ptr = (u32 *)data->physical_dev_id_ptr;
    u32 *vfid_ptr = (u32 *)data->vfid_ptr;
    int phy_devid;

    phy_devid = cgroup_find_nth_device(logical);
    if (phy_devid >= 0) {
      if (phy_ptr)
        *phy_ptr = (u32)phy_devid;
      if (vfid_ptr)
        *vfid_ptr = 0;
      regs->regs[0] = 0;
    }
  }
  return 0;
}

static struct kretprobe krp_logical_to_phy = {
    .entry_handler = entry_handler_l2p,
    .handler = ret_handler_l2p,
    .data_size = sizeof(struct logical_to_phy_data),
    .maxactive = 64,
    .kp.symbol_name = "devdrv_manager_container_logical_id_to_physical_id",
};

/* ============================================================
 * Module init/exit
 * ============================================================ */

struct hook_entry {
  struct kretprobe *krp;
  const char *name;
  bool registered;
};

static struct hook_entry hooks[] = {
    {&krp_can_access, "uda_can_access_udevid", false},
    {&krp_task_access, "uda_task_can_access_udevid", false},
    {&krp_proc_can_access, "uda_proc_can_access_udevid", false},
    {&krp_occupy, "uda_occupy_dev_by_ns", false},
    {&krp_devcgroup_allow, "uda_devcgroup_permission_allow", false},
    {&krp_devid_to_udevid, "uda_ns_node_devid_to_udevid", false},
    {&krp_logical_to_phy, "devdrv_manager_container_logical_id_to_physical_id",
     false},
};

static void cleanup_hooks(void) {
  int i;
  for (i = ARRAY_SIZE(hooks) - 1; i >= 0; i--) {
    if (hooks[i].registered) {
      unregister_kretprobe(hooks[i].krp);
      hooks[i].registered = false;
    }
  }
}

static int __init npu_bypass_init(void) {
  int i, ret;

  devcgroup_check_fn = (devcgroup_check_fn_t)kallsyms_lookup_name(
      "__devcgroup_check_permission");
  if (!devcgroup_check_fn) {
    pr_err("npu_bypass: __devcgroup_check_permission not found\n");
    return -ENOENT;
  }

  container_check_fn = (container_check_fn_t)kallsyms_lookup_name(
      "devdrv_manager_container_is_in_container");
  if (!container_check_fn)
    pr_warn("npu_bypass: devdrv_manager_container_is_in_container not found\n");

  pr_info("npu_bypass: davinci_major=%d\n", davinci_major);

  for (i = 0; i < ARRAY_SIZE(hooks); i++) {
    ret = register_kretprobe(hooks[i].krp);
    if (ret < 0) {
      pr_err("npu_bypass: hook %s failed: %d\n", hooks[i].name, ret);
      cleanup_hooks();
      return ret;
    }
    hooks[i].registered = true;
    pr_info("npu_bypass: hooked %s\n", hooks[i].name);
  }

  pr_info("npu_bypass: NPU container isolation bypass ACTIVE "
          "(%d hooks, cgroup-scan)\n",
          (int)ARRAY_SIZE(hooks));
  return 0;
}

static void __exit npu_bypass_exit(void) {
  cleanup_hooks();
  pr_info("npu_bypass: NPU container isolation bypass REMOVED\n");
}

module_init(npu_bypass_init);
module_exit(npu_bypass_exit);
