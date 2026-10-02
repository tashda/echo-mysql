# Testing echo-mysql

```bash
swift test
```

runs everything. Unit tests need no server. Integration tests (`Tests/MySQLIntegrationTests`) need a
MySQL or MariaDB server, which they find through one URL variable per setup. A suite whose variable is
not set is skipped, and the skip names the variable. With `MYSQL_TEST_REQUIRED=1` a missing variable
fails instead, which is how CI makes sure nothing passed by being skipped.

Tests create the schemas, tables, users and roles they need through echo-mysql's typed APIs, under
names starting `mwt_`, and remove them afterwards. Any disposable server works: Docker, a VM, or
echo-server-lab. Do not point the tests at a server whose data matters.

## Variables

| Variable | Server | Suites |
|---|---|---|
| `MYSQL_TEST_URL` | a plain MySQL or MariaDB server, with an administrator account | `ConnectionTests`, `SchemaTests`, `DataTests`, `SecurityTests`, `ProgrammabilityTests`, `ServerTests` |
| `MYSQL_TEST_TLS_URL` | a server that requires TLS; the URL carries the mode, the CA and a client certificate | `TLSTests` |
| `MYSQL_TEST_REPLICA_URL` | a replica following the `MYSQL_TEST_URL` server (both needed) | `ReplicationTests` |
| `MYSQL_TEST_PROXY_URL`, `MYSQL_TEST_PROXY_CONTROL` | the server through a Toxiproxy, and the proxy's HTTP API | `FaultTests` |
| `MYSQL_TEST_REQUIRED` | `1`: a missing variable fails the suite instead of skipping it | all |

## URL form

The form MySQL's own clients use. User and password are percent-encoded (`p%40ss` for `p@ss`); the
path names the database to connect to first (`/` for none).

```
mysql://root:pass@localhost:3306/?ssl-mode=PREFERRED
mysql://root:pass@host:3306/?ssl-mode=VERIFY_IDENTITY&ssl-ca=/ca.pem&ssl-cert=/client.pem&ssl-key=/client.key
```

`ssl-mode` is `DISABLED`, `PREFERRED` (the default), `REQUIRED`, `VERIFY_CA` or `VERIFY_IDENTITY`.
`connect-timeout` (seconds) is optional. `mariadb://` works too.

MySQL 8+ signs `root` in with `caching_sha2_password`, whose first login echo-mysql can only complete
over TLS. The official MySQL images generate a certificate, so `PREFERRED` works; so do MariaDB 11.4+
images. MariaDB 10.x images have no certificate and use `mysql_native_password`, which needs none.

## A plain server

```bash
docker run -d --name mysql-test -e MYSQL_ROOT_PASSWORD=Test-Password1 -p 3306:3306 mysql:8.4
MYSQL_TEST_URL='mysql://root:Test-Password1@127.0.0.1:3306/' swift test
```

The same with `mariadb:11.8` (or any version CI covers: `mysql:8.4`, `mysql:9`, `mariadb:10.11`,
`mariadb:11.4`, `mariadb:11.8`). Wait until the server accepts connections (`docker logs -f mysql-test`)
before running the tests.

## A server that requires TLS

A private CA, a server certificate for 127.0.0.1 and a client certificate:

```bash
mkdir certs && cd certs
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=test CA" -keyout ca.key -out ca.pem
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -extfile server.ext -out server.pem
openssl req -newkey rsa:2048 -nodes -subj "/CN=test client" -keyout client.key -out client.csr
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -out client.pem
chmod 644 ./*.pem ./*.key && cd ..

docker run -d --name mysql-tls -p 3307:3306 -v "$PWD/certs:/certs:ro" -e MYSQL_ROOT_PASSWORD=Test-Password1 mysql:8.4 \
  --require-secure-transport=ON --ssl-ca=/certs/ca.pem --ssl-cert=/certs/server.pem --ssl-key=/certs/server.key

MYSQL_TEST_TLS_URL="mysql://root:Test-Password1@127.0.0.1:3307/?ssl-mode=VERIFY_IDENTITY&ssl-ca=$PWD/certs/ca.pem&ssl-cert=$PWD/certs/client.pem&ssl-key=$PWD/certs/client.key" \
  swift test --filter TLSTests
```

`mariadb:11.8` takes the same options. Without `ssl-ca` the certificate checks are skipped, without
`ssl-cert`/`ssl-key` the client-certificate test.

## A source and a replica

```bash
docker network create replication
docker run -d --name source --network replication -p 3306:3306 -e MYSQL_ROOT_PASSWORD=Test-Password1 mysql:8.4 \
  --server-id=1 --log-bin=binlog --gtid-mode=ON --enforce-gtid-consistency=ON
docker run -d --name replica --network replication -p 3307:3306 -e MYSQL_ROOT_PASSWORD=Test-Password1 mysql:8.4 \
  --server-id=2 --log-bin=binlog --gtid-mode=ON --enforce-gtid-consistency=ON
# once both accept connections:
docker exec replica mysql -uroot -pTest-Password1 -e "CHANGE REPLICATION SOURCE TO SOURCE_HOST='source', \
  SOURCE_USER='root', SOURCE_PASSWORD='Test-Password1', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; \
  START REPLICA; SET GLOBAL super_read_only=ON;"

MYSQL_TEST_URL='mysql://root:Test-Password1@127.0.0.1:3306/' \
MYSQL_TEST_REPLICA_URL='mysql://root:Test-Password1@127.0.0.1:3307/' swift test --filter ReplicationTests
```

MariaDB: `--server-id=N --log-bin=binlog`, and on the replica
`CHANGE MASTER TO MASTER_HOST='source', MASTER_USER='root', MASTER_PASSWORD='Test-Password1', MASTER_USE_GTID=slave_pos; START SLAVE; SET GLOBAL read_only=ON;`.

## Network faults

```bash
docker network create faults
docker run -d --name mysql --network faults -e MYSQL_ROOT_PASSWORD=Test-Password1 mysql:8.4
docker run -d --name toxiproxy --network faults -p 8474:8474 -p 3307:3307 ghcr.io/shopify/toxiproxy:2.12.0
curl -X POST http://127.0.0.1:8474/proxies -d '{"name":"mysql","listen":"0.0.0.0:3307","upstream":"mysql:3306"}'

MYSQL_TEST_PROXY_URL='mysql://root:Test-Password1@127.0.0.1:3307/' \
MYSQL_TEST_PROXY_CONTROL='http://127.0.0.1:8474' swift test --filter FaultTests
```

The tests add latency, drop the link and swallow traffic through the proxy's API, and reset it after
each test.

## Known issues

Tests mark these with `withKnownIssue`; when one is fixed its test fails, and the marker goes.

- A connection that goes silent after login is not detected: statements have no deadline and the
  configuration's `keepAliveInterval` is not used; `FaultTests.silentLinkAfterLoginIsDetected`.

Closed by the switch to MariaDB Connector/C: DECIMAL and temporal values with binds, `REQUIRED`
without server TLS (now refused), the Linux connect stall, and the `sha256_password`, `client_ed25519`
and `parsec` logins. `caching_sha2_password` full authentication without TLS is refused by design
(decision D18) unless `serverPublicKeyPath` names the server's key.

## CI

`.github/workflows/test.yml`: build and unit tests (Swift 6.2), then integration tests against GitHub
service containers for MySQL 8.4 and 9 and MariaDB 10.11, 11.4 and 11.8, and one job each for TLS
(MySQL 8.4, MariaDB 11.8), replication (MySQL 8.4, MariaDB 11.8) and network faults, set up exactly
as above. Every job sets `MYSQL_TEST_REQUIRED=1`.

## With echo-server-lab

Maintainers with access to the lab run any recipe the same way; the lab sets the variables and
removes its servers when the command ends:

```bash
swift run --package-path ../echo-server-lab serverlab run --recipe mysql-8.4-empty -- swift test
swift run --package-path ../echo-server-lab serverlab run --recipe mysql-8.4-tls-client-certificate -- swift test --filter TLSTests
swift run --package-path ../echo-server-lab serverlab run --recipe mariadb-11.4-source-replica -- swift test --filter ReplicationTests
```
