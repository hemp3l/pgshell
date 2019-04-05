#!/bin/sh
#
# pg_shell test environment generation script
#
#
#

BIN_DIR="/opt/postgresql/bin/"
TEMP_DIR="/tmp/test-env/"
DB_USER="pgsql"
TEST_USER="someone"
TEST_DBNAME="testdb"
TEST_TABLE="testtab"


validate() {
  if [ $1 = $2 ] ; then
     echo "done"
  else
    echo "failed"
    exit 
  fi
}

echo " * generating test environment"

# TEMP DIR
echo -n "   - creating temporary directory $TEMP_DIR ..."
mkdir -p $TEMP_DIR
validate $? 0

# TEST USER
echo -n "   - creating non-superuser $TEST_USER ..."
$BIN_DIR/createuser --username=$DB_USER --no-superuser --no-createdb --no-createrole --quiet $TEST_USER
validate $? 0

# TEST DATABASE
echo -n "   - creating database $TEST_DBNAME ..."
$BIN_DIR/createdb --username=$DB_USER --quiet --owner $TEST_USER $TEST_DBNAME
validate $? 0

# TEST TABLE
echo -n "   - creating table $TEST_TABLE ..."
cat <<EOF | $BIN_DIR/psql --username=$DB_USER --quiet --dbname $TEST_DBNAME --username $TEST_USER
CREATE TABLE $TEST_TABLE (id INT, data TEXT);
INSERT INTO $TEST_TABLE (id, data) VALUES (1, 'abcdef');
INSERT INTO $TEST_TABLE (id, data) VALUES (2, 'ghijkl');
INSERT INTO $TEST_TABLE (id, data) VALUES (3, 'mnopqr');
INSERT INTO $TEST_TABLE (id, data) VALUES (4, 'stuvwx');
EOF
validate $? 0

# PHP SCRIPT
echo -n "   - creating php script ..."
cat <<EOF > $TEMP_DIR/test-env.php
<html>
  <head>
    <title>pg_shell test page</title>
  </head>

  <?
    \$id = \$_GET['id'];
    \$data = "";
    
    if (isset(\$id)) { 
      \$conn = pg_connect("dbname=$TEST_DBNAME user=$TEST_USER host=localhost");
      if (!\$conn) {
        die(pg_last_error(\$conn));
      }
    
    \$qry = pg_query(\$conn, "SELECT data FROM $TEST_TABLE WHERE id = \$id");
      if (!\$qry) {
        die(pg_last_error(\$conn));
      }
      
      if (\$res = pg_fetch_object(\$qry)) {
        \$data = \$res->data;
      }
    }
  ?>

  <body>
    <center>
      <table>
        <tr><td><b>id</b></td><td><? echo htmlentities(\$id); ?></td></tr>
	<tr><td><b>data</b></td><td><? echo htmlentities(\$data); ?></td></tr>
      </table>
    </center>
  </body>
</html>	
EOF
validate $? 0

# REQUEST FILE
echo -n "   - creating HTTP request file ..."
cat <<EOF > $TEMP_DIR/http-request
GET /test-env.php?id=1;<<INJECTION>> HTTP/1.0

EOF
validate $? 0

echo " * finished"

cat <<EOF

Please make sure, that 
   ... you have set up your web server to support php with PostgreSQL support
   ... you place $TEMP_DIR/test-env.php in your web document root directory
   ... you disable magic quotes in your php.ini
EOF
