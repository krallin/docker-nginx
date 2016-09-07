#!/usr/bin/env bats

install_heartbleed() {
  export GOPATH=/tmp/gocode
  export PATH=${PATH}:/usr/local/go/bin:${GOPATH}/bin
  go get github.com/FiloSottile/Heartbleed
  go install github.com/FiloSottile/Heartbleed
}

uninstall_heartbleed() {
  rm -rf ${GOPATH}
}

wait_for_nginx() {
  /usr/local/bin/nginx-wrapper > /tmp/nginx.log &
  while ! pgrep -x "nginx: worker process" > /dev/null ; do sleep 0.1; done
}

wait_for_proxy_protocol() {
  # This is really weird, but it appears NGiNX takes several seconds to
  # correctly handle Proxy Protocol requests
  haproxy -f ${BATS_TEST_DIRNAME}/haproxy.cfg
  while ! curl localhost:8080 &> /dev/null ; do sleep 0.1 ; done
}

local_s_client() {
  echo OK | openssl s_client -connect localhost:443 $@
}

simulate_upstream() {
  BATS_TEST_DIRNAME="$BATS_TEST_DIRNAME" "$BATS_TEST_DIRNAME"/upstream-server &
}

setup() {
  TMPDIR=$(mktemp -d)
  cp /usr/html/* "$TMPDIR"
}

teardown() {
  pkill nginx-wrapper || true
  pkill nginx || true
  pkill -f upstream-server || true
  pkill nc || true
  pkill haproxy || true
  rm -rf /etc/nginx/ssl/*
  cp "$TMPDIR"/* /usr/html
}

NGINX_VERSION=1.10.1

@test "It should install NGiNX $NGINX_VERSION" {
  run /usr/sbin/nginx -v
  [[ "$output" =~ "$NGINX_VERSION"  ]]
}

@test "It does not include the Nginx version" {
  wait_for_nginx
  run curl -v http://localhost
  echo "$output"
  [[ ! "$output" =~ "$NGINX_VERSION" ]]
}

@test "It should pass an external Heartbleed test" {
  skip
  install_heartbleed
  wait_for_nginx
  Heartbleed localhost:443
  uninstall_heartbleed
}

@test "It should accept large file uploads" {
  dd if=/dev/zero of=zeros.bin count=1024 bs=4096
  wait_for_nginx
  run curl -k --form upload=@zeros.bin --form press=OK https://localhost:443/
  [ "$status" -eq "0" ]
  [[ ! "$output" =~ "413"  ]]
}

@test "It should log to STDOUT" {
  wait_for_nginx
  curl localhost > /dev/null 2>&1
  [[ -s /tmp/nginx.log ]]
}

@test "It should log to STDOUT (Proxy Protocol)" {
  PROXY_PROTOCOL=true wait_for_nginx
  wait_for_proxy_protocol
  curl localhost:8080 > /dev/null 2>&1
  [[ -s /tmp/nginx.log ]]
}

@test "It should accept and configure a MAINTENANCE_PAGE_URL" {
  UPSTREAM_SERVERS=localhost:4000 \
    MAINTENANCE_PAGE_URL=https://www.aptible.com/404.html wait_for_nginx
  run curl localhost 2>/dev/null
  [[ "$output" =~ "@aptiblestatus" ]]
}

@test "It should accept a list of UPSTREAM_SERVERS" {
  simulate_upstream
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  run curl localhost 2>/dev/null
  [[ "$output" =~ "Hello World!" ]]
}

@test "It should accept a list of UPSTREAM_SERVERS (Proxy Protocol)" {
  simulate_upstream
  PROXY_PROTOCOL=true UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  wait_for_proxy_protocol
  run curl localhost:8080 2>/dev/null
  [[ "$output" =~ "Hello World!" ]]
}

@test "It should handle HTTPS over Proxy Protocol" {
  simulate_upstream
  PROXY_PROTOCOL=true UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  wait_for_proxy_protocol
  run curl -k https://localhost:8443 2>/dev/null
  [[ "$output" =~ "Hello World!" ]]
}

@test "It should honor FORCE_SSL" {
  FORCE_SSL=true wait_for_nginx
  run curl -I localhost 2>/dev/null
  [[ "$output" =~ "HTTP/1.1 301 Moved Permanently" ]]
  [[ "$output" =~ "Location: https://localhost" ]]
}

@test "It should send a Strict-Transport-Security header with FORCE_SSL" {
  FORCE_SSL=true wait_for_nginx
  run curl -Ik https://localhost 2>/dev/null
  [[ "$output" =~ "Strict-Transport-Security: max-age=31536000" ]]
}

@test "The Strict-Transport-Security header's max-age should be configurable" {
  FORCE_SSL=true HSTS_MAX_AGE=1234 wait_for_nginx
  run curl -Ik https://localhost 2>/dev/null
  [[ "$output" =~ "Strict-Transport-Security: max-age=1234" ]]
}

@test "Its OpenSSL client should support TLS_FALLBACK_SCSV" {
  FORCE_SSL=true wait_for_nginx
  run local_s_client -fallback_scsv
  [ "$status" -eq "0" ]
}

@test "It should support TLS_FALLBACK_SCSV by default" {
  FORCE_SSL=true wait_for_nginx
  run local_s_client -fallback_scsv -no_tls1_2
  [ "$status" -ne "0" ]
  [[ "$output" =~ "inappropriate fallback" ]]
}

@test "It should use at least a 2048 EDH key" {
  # TODO: re-enable this test once we're using OpenSSL v.1.0.2 or greater.
  skip
  FORCE_SSL=true wait_for_nginx
  run local_s_client -cipher "EDH"
  [[ "$output" =~ "Server Temp Key: DH, 2048 bits" ]]
}

@test "It should have at least a 2048 EDH key available" {
   # TODO: remove this test in favor of the previous test once possible.
   run openssl dhparam -in /etc/nginx/dhparams.pem -check -text
   [[ "$output" =~ "DH Parameters: (2048 bit)" ]]
}

@test "It disables export ciphers" {
  FORCE_SSL=true wait_for_nginx
  run local_s_client -cipher "EXP"
  [ "$status" -eq 1 ]
}

@test "It allows RC4 for SSLv3" {
  wait_for_nginx
  run local_s_client -cipher "RC4" -ssl3
  [ "$status" -eq 0 ]
}

@test "It disables block ciphers for SSLv3" {
  wait_for_nginx
  run local_s_client -cipher "AES" -ssl3
  [ "$status" -ne 0 ]
}

@test "It support block ciphers for TLSv1.x" {
  wait_for_nginx
  run local_s_client -cipher "AES" -tls1_2
  [ "$status" -eq 0 ]
}

@test "It allows CloudFront-supported ciphers when using SSLv3" {
  # To mitigate POODLE attacks, we don't allow ciphers running in CBC mode under SSLv3.
  # This leaves only RC4-MD5 as an option for custom origins behind CloudFront. See
  # http://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorCustomOrigin.html
  # for more detail.
  wait_for_nginx
  run local_s_client -cipher "RC4-MD5" -ssl3
  [ "$status" -eq 0 ]
}

@test "It allows underscores in headers" {
  rm /tmp/nc.log || true
  nc -l -p 4000 127.0.0.1 > /tmp/nc.log &
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  curl --header "NoUnderscores: true" --header "SOME_UNDERSCORES: true" --max-time 1 http://localhost
  run cat /tmp/nc.log
  [[ "$output" =~ "NoUnderscores: true" ]]
  [[ "$output" =~ "SOME_UNDERSCORES: true" ]]
}

@test "It does not allow SSLv3 if DISABLE_WEAK_CIPHER_SUITES is set" {
  DISABLE_WEAK_CIPHER_SUITES=true wait_for_nginx
  run local_s_client -ssl3
  [ "$status" -eq 1 ]
}

@test "It does not allow RC4 if DISABLE_WEAK_CIPHER_SUITES is set" {
  DISABLE_WEAK_CIPHER_SUITES=true wait_for_nginx
  run local_s_client -cipher "RC4"
  [ "$status" -eq 1 ]
}

@test "It allows ssl_ciphers to be overridden with SSL_CIPHERS_OVERRIDE" {
  SSL_CIPHERS_OVERRIDE="ECDHE-RSA-AES256-GCM-SHA384" wait_for_nginx
  run local_s_client -cipher ECDHE-RSA-AES256-GCM-SHA384
  [ "$status" -eq 0 ]
  run local_s_client -cipher ECDHE-ECDSA-AES256-GCM-SHA384
  [ "$status" -eq 1 ]
  run local_s_client -cipher ECDHE-RSA-AES128-GCM-SHA256
  [ "$status" -eq 1 ]
  run local_s_client -cipher DES-CBC-SHA
  [ "$status" -eq 1 ]
}

@test "It allows ssl_protocols to be overridden with SSL_PROTOCOLS_OVERRIDE" {
  SSL_PROTOCOLS_OVERRIDE="TLSv1.1 TLSv1.2" wait_for_nginx
  run local_s_client -ssl3
  [ "$status" -eq 1 ]
  run local_s_client -tls1
  [ "$status" -eq 1 ]
  run local_s_client -tls1_1
  [ "$status" -eq 0 ]
  run local_s_client -tls1_2
  [ "$status" -eq 0 ]
}

@test "It removes any semicolons in SSL_CIPHERS_OVERRIDE" {
  SSL_CIPHERS_OVERRIDE="ECDHE;;-RSA-AES256-GCM-SHA384;" wait_for_nginx
  run local_s_client -cipher ECDHE-RSA-AES256-GCM-SHA384
  [ "$status" -eq 0 ]
}

@test "It removes any semicolons in SSL_PROTOCOLS_OVERRIDE" {
  SSL_PROTOCOLS_OVERRIDE=";;;TLSv1.1; TLSv1.2;" wait_for_nginx
  run local_s_client -tls1_1
  [ "$status" -eq 0 ]
}

@test "It sets an X-Request-Start header" {
  # https://docs.newrelic.com/docs/apm/applications-menu/features/request-queue-server-configuration-examples#nginx
  rm /tmp/nc.log || true
  nc -l -p 4000 127.0.0.1 > /tmp/nc.log &
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  curl --max-time 1 http://localhost
  run cat /tmp/nc.log
  [[ "$output" =~ "X-Request-Start: t=" ]]
}

@test "It forces X-Forwarded-Proto = http for HTTP requests" {
  LOG="nc.log"
  UPSTREAM_OUT="$LOG" simulate_upstream
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  curl -s -H 'X-Forwarded-Proto: https' http://localhost

  grep 'X-Forwarded-Proto: http' "$LOG"
  run grep 'X-Forwarded-Proto: https' "$LOG"
  [[ "$status" -eq 1 ]]
}

@test "It forces X-Forwarded-Proto = https for HTTPS requests" {
  LOG="nc.log"
  UPSTREAM_OUT="$LOG" simulate_upstream
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  curl -sk -H 'X-Forwarded-Proto: http' https://localhost

  grep 'X-Forwarded-Proto: https' "$LOG"
}

@test "It drops the Proxy header (HTTP)" {
  LOG="nc.log"
  UPSTREAM_OUT="$LOG" simulate_upstream
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  curl -s -H 'Proxy: some' http://localhost

  run grep -i 'Proxy:' "$LOG"
  [[ "$status" -eq 1 ]]
}

@test "It drops the Proxy header (HTTP, lowercase)" {
  LOG="nc.log"
  UPSTREAM_OUT="$LOG" simulate_upstream
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  curl -s -H 'proxy: some' http://localhost

  run grep -i 'Proxy:' "$LOG"
  [[ "$status" -eq 1 ]]
}

@test "It drops the Proxy header (HTTPS)" {
  LOG="nc.log"
  UPSTREAM_OUT="$LOG" simulate_upstream
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  curl -sk -H 'Proxy: some' https://localhost

  run grep -i 'Proxy:' "$LOG"
  [[ "$status" -eq 1 ]]
}

@test "It supports GZIP compression of responses" {
  simulate_upstream
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  curl -H "Accept-Encoding: gzip" localhost | gunzip -c | grep "Hello World!"
}

@test "It includes an informative default error page" {
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  run curl http://localhost
  [[ "$output" =~ "application crashed" ]]
  [[ "$output" =~ "you are a visitor" ]]
  [[ "$output" =~ "you are the owner" ]]
}

@test "It redirects ACME requests if ACME_SERVER is set" {
  UPSTREAM_PORT=5000 UPSTREAM_RESPONSE="acme.txt" simulate_upstream
  simulate_upstream
  ACME_SERVER=localhost:5000 UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  run curl "http://localhost/.well-known/acme-challenge/123"
  [[ "$output" =~ 'ACME Response' ]]
  run curl "http://localhost/"
  [[ "$output" =~ 'Hello World!' ]]
}

@test "It does not redirect ACME requests if ACME_SERVER is unset" {
  UPSTREAM_PORT=5000 UPSTREAM_RESPONSE="acme.txt" simulate_upstream
  simulate_upstream
  UPSTREAM_SERVERS=localhost:4000 wait_for_nginx
  run curl "http://localhost/.well-known/acme-challenge/123"
  [[ "$output" =~ 'Hello World!' ]]
  run curl "http://localhost/"
  [[ "$output" =~ 'Hello World!' ]]
}

@test "It serves a static information page if ACME_PENDING is set" {
  ACME_PENDING="true" ACME_DOMAIN="some.domain.com" wait_for_nginx
  run curl "http://localhost/.well-known/acme-challenge/123"
  [[ "$output" =~ 'some.domain.com' ]]
  [[ "$output" =~ 'finish setting up' ]]
  run curl "http://localhost/"
  [[ "$output" =~ 'some.domain.com' ]]
  [[ "$output" =~ 'finish setting up' ]]
}

@test "When ACME is ready, it doesn't redirect to SSL without FORCE_SSL" {
  ACME_READY="true" wait_for_nginx

  run curl -sI localhost 2>/dev/null
  [[ "$output" =~ "HTTP/1.1 200 OK" ]]
  [[ ! "$output" =~ "HTTP/1.1 301 Moved Permanently" ]]

  run curl -Ik https://localhost 2>/dev/null
  [[ ! "$output" =~ "Strict-Transport-Security:" ]]
}

@test "When ACME is enabled with FORCE_SSL, it redirects to SSL and sets HSTS headers" {
  ACME_READY="true" FORCE_SSL="true" wait_for_nginx

  run curl -I localhost 2>/dev/null
  [[ "$output" =~ "HTTP/1.1 301 Moved Permanently" ]]
  [[ "$output" =~ "Location: https://localhost" ]]

  run curl -Ik https://localhost 2>/dev/null
  [[ "$output" =~ "Strict-Transport-Security:" ]]
}
