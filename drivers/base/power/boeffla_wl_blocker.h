/*
 * Author: andip71, 01.09.2017
 *
 * Version 1.2.0 (Templar backport, sm6250 4.14 adaptation)
 *
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 */

#define BOEFFLA_WL_BLOCKER_VERSION	"1.2.0"

/*
 * sm6250 safe default: WiFi background-scan + NETLINK only.
 * qcom_rx_wakelock deliberately excluded (breaks VoLTE/SMS paging).
 * Full Templar portable list intentionally NOT imported -- RMNET/IPA/USB/UART
 * entries are not inert on sm6250 and can break modem/USB/Bluetooth.
 */
#define LIST_WL_DEFAULT			"wlan;wlan_wow_wl;wlan_extscan_wl;NETLINK"

#define LENGTH_LIST_WL			1024
/* Both lists are sysfs-writable, so both get the full capacity. Deriving this
 * from strlen(LIST_WL_DEFAULT) is not a constant expression and capped any
 * replacement at the compiled default's length. */
#define LENGTH_LIST_WL_DEFAULT		LENGTH_LIST_WL
/* ";default;user;" -- three delimiters plus the terminator. */
#define LENGTH_LIST_WL_SEARCH		(LENGTH_LIST_WL_DEFAULT + LENGTH_LIST_WL + 4)
