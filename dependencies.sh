#!/bin/sh
apt-get update
apt-get install -y --no-install-recommends \
	ca-certificates \
	cpanminus \
	git \
	libconfig-properties-perl \
	libparams-validate-perl \
	libproc-background-perl \
	make \
	perl \
	python-is-python3 \
	python3 \
	python3-coverage

cpanm --notest Config::Properties::Simple

git clone --depth 1 https://github.com/web-cat/web-cat-subsystem-PerlForPlugins.git /tmp/PerlForPlugins
mkdir -p /usr/local/lib/site_perl
cp -R /tmp/PerlForPlugins/Resources/lib/. /usr/local/lib/site_perl/
rm -rf /tmp/PerlForPlugins

apt-get purge -y --auto-remove cpanminus git make
rm -rf /var/lib/apt/lists/* /root/.cpanm
