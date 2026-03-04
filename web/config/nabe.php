<?php

return [
    'ad_domain'         => env('NABE_AD_DOMAIN', 'lab.local'),
    'ad_server'         => env('NABE_AD_SERVER', '10.10.0.3'),
    'ad_hostname'       => env('NABE_AD_HOSTNAME', 'win-6gehanhp56q.lab.local'),
    'ad_base_dn'        => env('NABE_AD_BASE_DN', 'DC=lab,DC=local'),
    'group_install'     => env('NABE_GROUP_INSTALL', 'NetBoot-Install'),
    'group_admin'       => env('NABE_GROUP_ADMIN', 'NetBoot-Admin'),
    'server_ip'         => env('NABE_SERVER_IP', '10.10.0.2'),
    'iscsi_iqn_prefix'  => env('NABE_ISCSI_IQN_PREFIX', 'iqn.2024-01.local.lab.netboot'),
    'iscsi_manage'      => env('NABE_ISCSI_MANAGE', '/opt/netboot-auth/iscsi-manage.sh'),
    'session_timeout'   => env('NABE_SESSION_TIMEOUT', 5),
];
