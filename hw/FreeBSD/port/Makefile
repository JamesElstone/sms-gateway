PORTNAME=	sms-gateway
DISTVERSION=	0.1.0
CATEGORIES=	www comms

MAINTAINER=	james@elstone.net
COMMENT=	PHP SMS gateway for Huawei HiLink LTE modems
WWW=		https://github.com/JamesElstone/sms-gateway

LICENSE=	BSD3CLAUSE
LICENSE_FILE=	${WRKSRC}/LICENSE

USES=		php:web
USE_GITHUB=	yes
GH_ACCOUNT=	JamesElstone
GH_TAGNAME=	8486a21cfa89e7c5222157aed5afeeca055edb79
USE_PHP=	curl dom filter mbstring

NO_ARCH=	yes
NO_BUILD=	yes

IGNORE_WITH_PHP=	80

PLIST_FILES=	etc/rc.d/sms_gateway

PORTDOCS=	API.md DEPLOYMENT.md FreeBSD-README.md README.md

OPTIONS_DEFINE=		APACHE DOCS
OPTIONS_DEFAULT=	APACHE

APACHE_DESC=		Install Apache 2.4 include file
APACHE_USE=		APACHE=24
APACHE_PLIST_FILES=	etc/apache24/Includes/sms-gateway.conf

do-install:
	${MKDIR} ${STAGEDIR}${WWWDIR} \
		${STAGEDIR}${WWWDIR}/config \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/apache24 \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/rc.d \
		${STAGEDIR}${WWWDIR}/public \
		${STAGEDIR}${WWWDIR}/src
	cd ${WRKSRC}/config && ${COPYTREE_SHARE} . ${STAGEDIR}${WWWDIR}/config
	cd ${WRKSRC}/public && ${COPYTREE_SHARE} . ${STAGEDIR}${WWWDIR}/public
	cd ${WRKSRC}/src && ${COPYTREE_SHARE} . ${STAGEDIR}${WWWDIR}/src
	${INSTALL_DATA} ${WRKSRC}/LICENSE ${STAGEDIR}${WWWDIR}/
	${INSTALL_DATA} ${WRKSRC}/hw/FreeBSD/README.md ${STAGEDIR}${WWWDIR}/hw/FreeBSD/
	${INSTALL_DATA} ${WRKSRC}/hw/FreeBSD/apache24/sms-gateway.conf \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/apache24/
	${INSTALL_SCRIPT} ${WRKSRC}/config/set_token.sh ${STAGEDIR}${WWWDIR}/config/
	${INSTALL_SCRIPT} ${WRKSRC}/hw/FreeBSD/install-huawei-lte.sh \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/
	${INSTALL_SCRIPT} ${WRKSRC}/hw/FreeBSD/rc.d/sms_gateway \
		${STAGEDIR}${WWWDIR}/hw/FreeBSD/rc.d/
	${MKDIR} ${STAGEDIR}${PREFIX}/etc/rc.d
	${SED} -e 's|/usr/local/sms-gateway|${WWWDIR}|g' \
		${WRKSRC}/hw/FreeBSD/rc.d/sms_gateway > \
		${STAGEDIR}${PREFIX}/etc/rc.d/sms_gateway
	${CHMOD} ${BINMODE} ${STAGEDIR}${PREFIX}/etc/rc.d/sms_gateway

post-install:
	cd ${STAGEDIR}${PREFIX} && \
		${FIND} ${WWWDIR_REL} -type f | ${SORT} >> ${TMPPLIST}

post-install-APACHE-on:
	${MKDIR} ${STAGEDIR}${PREFIX}/etc/apache24/Includes
	${SED} -e 's|/usr/local/sms-gateway|${WWWDIR}|g' \
		${WRKSRC}/hw/FreeBSD/apache24/sms-gateway.conf > \
		${STAGEDIR}${PREFIX}/etc/apache24/Includes/sms-gateway.conf

post-install-DOCS-on:
	${MKDIR} ${STAGEDIR}${DOCSDIR}
	${INSTALL_DATA} ${WRKSRC}/API.md ${STAGEDIR}${DOCSDIR}/
	${INSTALL_DATA} ${WRKSRC}/DEPLOYMENT.md ${STAGEDIR}${DOCSDIR}/
	${INSTALL_DATA} ${WRKSRC}/README.md ${STAGEDIR}${DOCSDIR}/
	${INSTALL_DATA} ${WRKSRC}/hw/FreeBSD/README.md \
		${STAGEDIR}${DOCSDIR}/FreeBSD-README.md

.include <bsd.port.mk>
