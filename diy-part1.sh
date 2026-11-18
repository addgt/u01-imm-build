#!/bin/bash
# DIY�ű�
# https://github.com/P3TERX/Actions-OpenWrt
# �ļ���: diy-part1.sh
# ����˵��: OpenWrt DIY�ű���1���֣�����feeds֮ǰ��
# ��Ȩ: (c) 2019-2024 P3TERX <https://p3terx.com>
# ���� MIT ��ԴЭ�飬��� /LICENSE

# ȡ��ע��һ��Դ
# sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# ���ӵ����� feed Դ��small-package ���� openclash/passwall/ssr-plus �ȳ��ò����
echo 'src-git smpackage https://github.com/kenzok8/small-package' >> feeds.conf.default
# ���ӵ�����Դ��iStore Ӧ���̵꣬����ʱ�������� luci-app-store
echo 'src-git store https://github.com/linkease/istore.git;main' >> feeds.conf.default


# OpenClash����
# git clone --depth 1 https://github.com/vernesong/OpenClash.git OpenClash

# turboacc������٣���Ҫ�û���ҳ��ѡ�� luci-app-turboacc ���ɱ���ű��Զ�ִ�У��˴��������������У�
# curl -sSL https://raw.githubusercontent.com/mufeng05/turboacc/main/add_turboacc.sh -o add_turboacc.sh && bash add_turboacc.sh

# ����
# sed -i 's|src-git-full openstick https://github.com/lkiuyu/openstick-feeds.git|src-git-full openstick https://github.com/xuxin1955/openstick-feeds|g' feeds.conf.default

# U01 run#10: 别人那版独有的三颗（后台频段页 netspeedtest/modeminfo/mmconfig）
echo 'src-git mmconfig https://github.com/erdoukki/luci-app-mmconfig.git;main' >> feeds.conf.default
echo 'src-git modeminfo https://github.com/4IceG/luci-app-modeminfo.git;master' >> feeds.conf.default
echo 'src-git muink https://github.com/muink/luci-app-netspeedtest.git;master' >> feeds.conf.default
