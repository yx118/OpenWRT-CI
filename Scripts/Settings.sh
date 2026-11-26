#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} +
#修改默认主题
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} +
#修改immortalwrt.lan关联IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} +
#添加编译日期标识
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} +

#修改默认WIFI账号密码
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
ROUTER_TOOL="./package/emortal/luci-app-router-tool/root/etc/config/router-tool"
for file in "$ROUTER_TOOL" "$WIFI_UC"; do
	[ -f "$file" ] && sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$file"
done

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
#主题配套应用（vantage 等有 luci-app-*，aurora 无此包时 defconfig 自动忽略）
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
#WIFI-NO 时缩小 Q6（WiFi 子系统）保留内存。两条策略：
#  1) 源码树自带 ipq6018/ipq8074-nowifi.dtsi（VIKINGYFY 分支）→ 改设备 dts 的 include，与改动前行为一致
#  2) 树内没有 nowifi dtsi（LibWrt 主线）→ 把 DTS/ 下的覆写片段拷进 dts 目录，追加到设备 dts 末尾
#两条策略都不适用时只保留「移除 ath11k 包」，构建继续，不中断
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* && "$WRT_WIFI" == "WIFI-NO" ]]; then
	DTS_DEVICE_DIR="./target/linux/qualcommax/dts"
	DTS_OVERLAY="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom"
	TREE_NOWIFI=0

	for DIR in "$DTS_DEVICE_DIR" "$DTS_OVERLAY"; do
		[ -d "$DIR" ] || continue
		if [ -f "$DIR/ipq6018-nowifi.dtsi" ] || [ -f "$DIR/ipq8074-nowifi.dtsi" ]; then
			TREE_NOWIFI=1
			break
		fi
	done

	if [ "$TREE_NOWIFI" = "1" ] && [ -d "$DTS_DEVICE_DIR" ]; then
		#树内已有 nowifi dtsi：只改设备 dts 的 include，不动 SoC 级 dtsi（避免重复包含）
		find "$DTS_DEVICE_DIR" -maxdepth 1 -type f ! -iname '*nowifi*' -exec sed -i 's/"ipq\(6018\|8074\).dtsi"/"ipq\1-nowifi.dtsi"/g' {} +
		echo "qualcommax set up nowifi successfully (in-tree dtsi)!"
	elif [ "$TREE_NOWIFI" = "0" ] && [ -d "$GITHUB_WORKSPACE/DTS" ] && [ -d "$DTS_OVERLAY" ]; then
		NOWIFI_APPLIED=0
		cp -f "$GITHUB_WORKSPACE"/DTS/*.dtsi "$DTS_OVERLAY"/ 2>/dev/null

		for FILE in "$DTS_OVERLAY"/*.dts "$DTS_OVERLAY"/*.dtsi; do
			[ -f "$FILE" ] || continue

			BASE=$(basename "$FILE")
			#跳过 SoC 级 dtsi，只处理设备级 dts/dtsi，避免重复包含
			case "$BASE" in
				ipq6018*|ipq8074*) continue ;;
			esac

			NOWIFI=""
			if grep -q '"ipq6018.dtsi"\|"ipq6018-512m.dtsi"' "$FILE"; then
				NOWIFI="ipq6018-nowifi.dtsi"
			fi
			if grep -q '"ipq8074.dtsi"' "$FILE"; then
				NOWIFI="ipq8074-nowifi.dtsi"
			fi
			[ -n "$NOWIFI" ] || continue
			[ -f "$DTS_OVERLAY/$NOWIFI" ] || continue
			grep -q "\"$NOWIFI\"" "$FILE" && continue

			printf '\n#include "%s"\n' "$NOWIFI" >> "$FILE"
			NOWIFI_APPLIED=$((NOWIFI_APPLIED + 1))
			echo "qualcommax nowifi overlay appended: $BASE -> $NOWIFI"
		done

		if [ "$NOWIFI_APPLIED" -gt 0 ]; then
			echo "qualcommax set up nowifi successfully (overlay dtsi)!"
		else
			echo "qualcommax nowifi skipped: no matching device dts, WIFI-NO keeps package stripping only"
		fi
	else
		echo "qualcommax nowifi skipped: no nowifi dtsi and no DTS/ overlay, WIFI-NO keeps package stripping only"
	fi
fi
