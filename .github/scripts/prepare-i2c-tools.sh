#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -euo pipefail

I2C_MAKEFILE=feeds/packages/utils/i2c-tools/Makefile

if [ ! -f "$I2C_MAKEFILE" ]; then
	echo "i2c-tools: package not present, skipped"
	exit 0
fi

# 不同源码树/feed 的 i2c-tools Makefile 结构可能不同（VIKINGYFY fork vs immortalwrt 上游），
# 锚点缺失时直接跳过，避免在 bash -e 下中断整个构建。
if ! grep -Fqx 'PKG_BUILD_DEPENDS:=python-setuptools/host' "$I2C_MAKEFILE" ||
	! grep -Fq '$(call Py3Build/Compile)' "$I2C_MAKEFILE" ||
	! grep -Fq '$(call Py3Build/Install)' "$I2C_MAKEFILE"; then
	echo "i2c-tools: Makefile layout differs from expectation, SMBus conditional patch skipped"
	exit 0
fi

# Build the Python SMBus binding only when its package is selected. The C
# tools remain available for device profiles that only install i2c-tools.
if ! grep -Fqx 'PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_python3-smbus' "$I2C_MAKEFILE"; then
	# Keep the Make expressions literal; they are intentionally not shell-expanded.
	# shellcheck disable=SC2016
	sed -i \
		-e 's/^PKG_BUILD_DEPENDS:=python-setuptools\/host$/PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_python3-smbus\nPKG_BUILD_DEPENDS:=PACKAGE_python3-smbus:python-setuptools\/host/' \
		-e 's/^\t$(call Py3Build\/Compile)$/\t$(if $(CONFIG_PACKAGE_python3-smbus),$(call Py3Build\/Compile))/' \
		-e 's/^\t$(call Py3Build\/Install)$/\t$(if $(CONFIG_PACKAGE_python3-smbus),$(call Py3Build\/Install))/' \
		-e 's/^  DEPENDS:=+libi2c +python3-light$/  DEPENDS:=+libi2c +PACKAGE_python3-smbus:python3-light/' \
		"$I2C_MAKEFILE"
fi

# 校验改为软失败：结构差异只告警，构建继续（补丁失效不影响 i2c-tools 本体可用）
for PATTERN in \
	'PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_python3-smbus' \
	'PKG_BUILD_DEPENDS:=PACKAGE_python3-smbus:python-setuptools/host' \
	'  DEPENDS:=+libi2c +PACKAGE_python3-smbus:python3-light'; do
	grep -Fqx "$PATTERN" "$I2C_MAKEFILE" || echo "warning: i2c-tools patch not applied as expected: $PATTERN"
done

if ! grep -Fq '$(if $(CONFIG_PACKAGE_python3-smbus),$(call Py3Build/Compile))' "$I2C_MAKEFILE"; then
	echo "warning: i2c-tools Py3Build/Compile is not conditional on python3-smbus"
fi
