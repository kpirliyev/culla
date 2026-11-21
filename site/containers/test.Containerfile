# The image site/test.sh runs the site's tests in: the Python unit tests, the
# deploy tests and the nginx tests. It is the official nginx image (the nginx
# the tests check) with what the test scripts need on top. site/test.sh
# builds it locally as localhost/culla-site-test:<hash of this file and the
# base image>, so it is rebuilt only when either changes. Nothing in it is
# published.
#
# NGINX_IMAGE is set by site/test.sh (CULLA_NGINX_IMAGE overrides it).
ARG NGINX_IMAGE=docker.io/library/nginx:1.26.3-bookworm
FROM ${NGINX_IMAGE}

# python3: count.py, the unit tests, the checks of the nginx logs.
# rsync: deploy.sh against the stand-in server.
# curl, openssl, gzip, tar, perl and logger come with the nginx image.
# shasum (SHA-1, as the tests use it) is Debian's sha1sum under the macOS name.
# tester: the deploy tests must not run as root.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 rsync \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/bin/sha1sum /usr/local/bin/shasum \
 && useradd --create-home --uid 1000 --shell /bin/bash tester

# The test scripts refuse to change /etc/nginx unless this is set.
ENV CULLA_IN_CONTAINER=1 PYTHONDONTWRITEBYTECODE=1
ENTRYPOINT []
CMD ["bash"]
