# Copyright (c) 2026, James Elstone
# SPDX-License-Identifier: BSD-3-Clause
#
# This file is part of SMS Gateway:
# https://github.com/JamesElstone/sms-gateway
#
# See LICENSE for details.
PORTNAME=	sms-gateway
DISTVERSION=	1.0.0
CATEGORIES=	comms www

MAINTAINER=	james@elstone.net
COMMENT=	PHP SMS gateway for Huawei HiLink LTE modems
WWW=		https://github.com/JamesElstone/sms-gateway

LICENSE=	BSD3CLAUSE
LICENSE_FILE=	${WRKSRC}/LICENSE

USES=		php:web
USE_GITHUB=	yes
GH_ACCOUNT=	JamesElstone
GH_TAGNAME=	v1.0.0
USE_PHP=	curl dom filter mbstring pdo pdo_sqlite simplexml sqlite3 xml

RUN_DEPENDS=	${LOCALBASE}/bin/sqlite3:databases/sqlite3 \
		${LOCALBASE}/sbin/usb_modeswitch:sysutils/usb_modeswitch

SMS_GATEWAY_DBDIR=	/var/db/${PORTNAME}
SMS_GATEWAY_LOGDIR=	/var/log/${PORTNAME}

NO_ARCH=	yes
NO_BUILD=	yes
SUB_FILES=	pkg-message sms-gateway-newsyslog.conf
SUB_LIST=	SMS_GATEWAY_DBDIR=${SMS_GATEWAY_DBDIR} \
		SMS_GATEWAY_LOGDIR=${SMS_GATEWAY_LOGDIR}

IGNORE_WITH_PHP=	80

PLIST_FILES=	etc/rc.d/sms_gateway \
		libexec/sms-gateway-newsyslog

PORTDOCS=	API.md DEPLOYMENT.md FreeBSD-README.md PRIVACY.md README.md

OPTIONS_DEFINE=		APACHE DOCS
OPTIONS_DEFAULT=	APACHE

APACHE_DESC=		Install Apache 2.4 include file
APACHE_RUN_DEPENDS=	apache24>0:www/apache24 \
			mod_php${PHP_VER}>0:www/mod_php${PHP_VER}
APACHE_PLIST_FILES=	etc/apache24/Includes/sms-gateway.conf

do-install:
	${MKDIR} ${STAGEDIR}${WWWDIR} \
		${STAGEDIR}${WWWDIR}/config \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/apache24 \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/newsyslog \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/rc.d \
		${STAGEDIR}${WWWDIR}/public \
		${STAGEDIR}${WWWDIR}/src \
		${STAGEDIR}${SMS_GATEWAY_DBDIR} \
		${STAGEDIR}${SMS_GATEWAY_LOGDIR} \
		${STAGEDIR}${PREFIX}/etc/newsyslog.conf.d \
		${STAGEDIR}${PREFIX}/libexec
	cd ${WRKSRC}/config && ${COPYTREE_SHARE} . ${STAGEDIR}${WWWDIR}/config
	${SED} -e "s|^[[:space:]]*'database_dsn'[[:space:]]*=>.*|    'database_dsn' => getenv('SMS_GATEWAY_DATABASE_DSN') ?: 'sqlite:${SMS_GATEWAY_DBDIR}/sms-gateway.sqlite3',|" \
		${WRKSRC}/config/local.php.example > \
		${STAGEDIR}${WWWDIR}/config/local.php.sample
	cd ${WRKSRC}/public && ${COPYTREE_SHARE} . ${STAGEDIR}${WWWDIR}/public
	cd ${WRKSRC}/src && ${COPYTREE_SHARE} . ${STAGEDIR}${WWWDIR}/src
	${INSTALL_DATA} ${WRKSRC}/LICENSE ${STAGEDIR}${WWWDIR}/
	${INSTALL_DATA} ${WRKSRC}/hw/FreeBSD/README.md ${STAGEDIR}${WWWDIR}/hw/FreeBSD/
	${INSTALL_DATA} ${WRKSRC}/hw/FreeBSD/apache24/sms-gateway.conf \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/apache24/
	${INSTALL_SCRIPT} ${WRKSRC}/config/set_token.sh ${STAGEDIR}${WWWDIR}/config/
	${INSTALL_SCRIPT} ${WRKSRC}/hw/FreeBSD/install-huawei-lte.sh \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/
	${INSTALL_SCRIPT} ${WRKSRC}/hw/FreeBSD/newsyslog/sms-gateway-newsyslog \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/newsyslog/
	${INSTALL_SCRIPT} ${WRKSRC}/hw/FreeBSD/rc.d/sms_gateway \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/rc.d/
	${MKDIR} ${STAGEDIR}${PREFIX}/etc/rc.d
	${SED} -e 's|/usr/local/sms-gateway|${WWWDIR}|g' \
		${WRKSRC}/hw/FreeBSD/rc.d/sms_gateway > \
		${WRKDIR}/sms_gateway
	${INSTALL_SCRIPT} ${WRKDIR}/sms_gateway \
		${STAGEDIR}${PREFIX}/etc/rc.d/sms_gateway
	${INSTALL_SCRIPT} ${WRKSRC}/hw/FreeBSD/newsyslog/sms-gateway-newsyslog \
		${STAGEDIR}${PREFIX}/libexec/sms-gateway-newsyslog
	${INSTALL_DATA} ${WRKDIR}/sms-gateway-newsyslog.conf \
		${STAGEDIR}${PREFIX}/etc/newsyslog.conf.d/sms-gateway.conf.sample

post-install:
	cd ${STAGEDIR}${PREFIX} && \
		${FIND} ${WWWDIR_REL} -type f ! -path ${WWWDIR_REL}/config/local.php.sample | \
		${SORT} >> ${TMPPLIST}
	${ECHO_CMD} "@sample ${WWWDIR_REL}/config/local.php.sample" >> ${TMPPLIST}
	${ECHO_CMD} "@sample etc/newsyslog.conf.d/sms-gateway.conf.sample" >> ${TMPPLIST}
	${ECHO_CMD} "@dir(www,www,0750) ${SMS_GATEWAY_DBDIR}" >> ${TMPPLIST}
	${ECHO_CMD} "@dir(root,www,0750) ${SMS_GATEWAY_LOGDIR}" >> ${TMPPLIST}

post-install-APACHE-on:
	${MKDIR} ${STAGEDIR}${PREFIX}/etc/apache24/Includes
	${SED} -e 's|/usr/local/sms-gateway|${WWWDIR}|g' \
		${WRKSRC}/hw/FreeBSD/apache24/sms-gateway.conf > \
		${STAGEDIR}${PREFIX}/etc/apache24/Includes/sms-gateway.conf

post-install-DOCS-on:
	${MKDIR} ${STAGEDIR}${DOCSDIR}
	${INSTALL_DATA} ${WRKSRC}/API.md ${STAGEDIR}${DOCSDIR}/
	${INSTALL_DATA} ${WRKSRC}/DEPLOYMENT.md ${STAGEDIR}${DOCSDIR}/
	${INSTALL_DATA} ${WRKSRC}/PRIVACY.md ${STAGEDIR}${DOCSDIR}/
	${INSTALL_DATA} ${WRKSRC}/README.md ${STAGEDIR}${DOCSDIR}/
	${INSTALL_DATA} ${WRKSRC}/hw/FreeBSD/README.md \
		${STAGEDIR}${DOCSDIR}/FreeBSD-README.md

.include <bsd.port.mk>
