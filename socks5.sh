#!/bin/bash

SOCKS5_INSTALL_PATH="/usr/local"

INSTALL_SOCKS5() {
    if [ -e /etc/opt/ss5/ss5.conf ]; then
        echo "SOCKS5 已安装."
        exit
    fi

    # 检查系统并安装依赖
    if [[ -f /etc/redhat-release ]]; then
        yum install -y gcc wget pam-devel openldap-devel openssl-devel
    else
        echo "仅支持 CentOS 系统."
        exit
    fi

    # 下载并安装 SOCKS5
    wget -P ${SOCKS5_INSTALL_PATH} "http://downloads.sourceforge.net/project/ss5/ss5/3.8.9-8/ss5-3.8.9-8.tar.gz"
    cd ${SOCKS5_INSTALL_PATH} && tar -xzf ss5-3.8.9-8.tar.gz && cd ss5-3.8.9
    ./configure && make && make install

    # 配置 SOCKS5
    sed -i '87c auth    0.0.0.0/0               -              u' /etc/opt/ss5/ss5.conf
    sed -i '203c permit  u       0.0.0.0/0       -       0.0.0.0/0       -       -       -       -       -' /etc/opt/ss5/ss5.conf
    echo "123456 654321" > /etc/opt/ss5/ss5.passwd

    # 开机自启并启动服务
    chmod u+x /etc/rc.d/init.d/ss5
    chkconfig --add ss5 && chkconfig ss5 on
    service ss5 start

    echo "SOCKS5 安装完成. 用户: 123456 密码: 654321 端口: 5555"
}

INSTALL_SOCKS5
