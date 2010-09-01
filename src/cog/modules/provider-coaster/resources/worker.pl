#!/usr/bin/perl
# Args:
# 	<URIs> <blockid> <logdir>
#	where:
#		<URIs> - comma separated list of URIs for the coaster service; they
#				will be tried in order
#		<blockid> - some block id (the log file will be named based on this)
#		<logdir> - some directory in which the logs should go
#

use IO::Socket;
use File::Basename;
use File::Path;
use File::Copy;
use Time::HiRes qw(time);
use Cwd;
use POSIX ":sys_wait_h";
use strict;
use warnings;

# If ASYNC is on, the following will be done:
#   1. Stageouts will be done in parallel
#   2. The job status will be set to "COMPLETED" as soon as the last
#      file is staged out (and before any cleanup is done).
use constant ASYNC => 1;

use constant {
	TRACE => 0,
	DEBUG => 1,
	INFO => 2,
	WARN => 3,
	ERROR => 4,
};

use constant {
	CONTINUE => 0,
	YIELD => 1,
};

my $LOGLEVEL = DEBUG;

my @LEVELS = ("TRACE", "DEBUG", "INFO ", "WARN ", "ERROR"); 

use constant {
	REPLY_FLAG => 0x00000001,
	FINAL_FLAG => 0x00000002,
	ERROR_FLAG => 0x00000004,
	PROGRESSIVE_FLAG => 0x00000008
};

use constant {
	COMPLETED => 0x07,
	FAILED => 0x05,
	ACTIVE => 0x02,
	STAGEIN => 0x10,
	STAGEOUT => 0x11,
};

my $TAG = 0;
use constant RETRIES => 3;
use constant REPLYTIMEOUT => 180;
use constant MAXFRAGS => 16;
use constant MAX_RECONNECT_ATTEMPTS => 3;

use constant IDLETIMEOUT => 4 * 60; #Seconds; 2 minutes
my $LASTRECV = 0;
my $JOBS_RUNNING = 0;

my $JOB_COUNT = 0;

use constant BUFSZ => 2048;

# 60 seconds by default. Note that since there is no configuration handshake
# this would have to match the default interval in the service in order to avoid
# "lost heartbeats".
use constant HEARTBEAT_INTERVAL => 2 * 60;

# Command-line arguments:
my $URISTR=$ARGV[0];
my $BLOCKID=$ARGV[1];
my $LOGDIR=$ARGV[2];


# REQUESTS holds a map of incoming requests
my %REQUESTS = ();

# REPLIES stores the state of (outgoing) commands for which replies are expected
my %REPLIES  = ();

my $LOG = logfilename($LOGDIR, $BLOCKID);

my %HANDLERS = (
	"SHUTDOWN"  => \&shutdownw,
	"SUBMITJOB" => \&submitjob,
	"REGISTER"  => \&register,
	"HEARTBEAT" => \&heartbeat,
	"WORKERSHELLCMD" => \&workershellcmd,
);

my @CMDQ = ();

my $ID = "-";

my @URIS = split(/,/, $URISTR); 
my @SCHEME;
my @HOSTNAME;
my @PORT;
my $URI;
foreach $URI (@URIS) {
	if ($URI =~ /(.*):\/\//) { push(@SCHEME, $1); } else { die "Could not parse url scheme: $URI"; }
	if ($URI =~ /.*:\/\/(.*):/) { push(@HOSTNAME, $1); } else { die "Could not parse url hostname: $URI"; }
	if ($URI =~ /.*:\/\/.*:(.*)/) { push(@PORT, $1); } else { die "Could not parse url port: $URI"; }
}
my $SOCK;
my $LAST_HEARTBEAT = 0;

my %JOBWAITDATA = ();
my %JOBDATA = ();

sub logfilename {
	$LOGDIR = shift;
	$BLOCKID = shift;
	my $result = undef;
	my $uci;
	if (-r "/proc/personality.sh") {
		$uci = get_bg_uci();
		$result = "$LOGDIR/worker-$BLOCKID-$uci.log";
	}
	else {
		$result = "$LOGDIR/worker-$BLOCKID.log";
	}
	return $result;
}

# Get the BlueGene Universal Component Identifier from Zepto 
sub get_bg_uci() {
	my %vars = file2hash("/proc/personality.sh");
	my $uci = $vars{"BG_UCI"};
	return $uci;
}

# Read a file into a hash, with file formatted as: 
# KEY=VALUE
sub file2hash() {
	my $file = shift;
	my %hash;
	open FILE, "<$file";
	while (<FILE>) {
		chomp;
		my ($key, $val) = split /=/;
		$hash{$key} = $val;
	}
	close FILE;
	return %hash;
}

sub wlog {
	my $msg;
	my $level = shift;
	if ($level >= $LOGLEVEL) {
		foreach $msg (@_) {
		        my $timestamp = timestring();
			my $msgline = sprintf("%s %s %s %s", 
					      $timestamp,
					      $LEVELS[$level], 
					      $ID, $msg);
			print LOG $msgline;
		}
	}
	return 1;
}

sub timestring() {
	my $t = sprintf("%.3f", time());
	#my @d = localtime(time());
	#my $t = sprintf("%i/%02i/%02i %02i:%02i",
	# $d[5]+1900, $d[4], $d[3], $d[2], $d[1]);
	return $t;
}

sub hts {
	my ($H) = @_;
	
	my $k;	
	my $s = "{";
	my $first = 1;
	
	for $k (keys %$H) {
		if (!$first) {
			$s = $s.", ";
		}
		else {
			$first = 0;
		}
		$s = $s."$k = $$H{$k}";
	}
      
	return $s."}";
}

sub reconnect() {
	my $fail = 0;
	my $success;
	my $i;
	my $j; 
	for ($i = 0; $i < MAX_RECONNECT_ATTEMPTS; $i++) {
		wlog INFO, "Connecting ($i)...\n";
		my $sz = @HOSTNAME;
		$success = 0;
		for ($j = 0; $j < $sz; $j++) {
			wlog DEBUG, "Trying $HOSTNAME[$j]:$PORT[$j]...\n";
			$SOCK = IO::Socket::INET->new(Proto=>'tcp', PeerAddr=>$HOSTNAME[$j], PeerPort=>$PORT[$j], Blocking=>1) || ($fail = 1);
			if (!$fail) {
				$success = 1;
				last;
			}
			else {
				wlog DEBUG, "Connection failed: $!. Trying other addresses\n"; 
			}
		}
		if ($success) {
			$SOCK->setsockopt(SOL_SOCKET, SO_RCVBUF, 16384);
			$SOCK->setsockopt(SOL_SOCKET, SO_SNDBUF, 32768);
			wlog INFO, "Connected\n";
			$SOCK->blocking(0);
			queueCmd(registerCB(), "REGISTER", $BLOCKID, "");
			last;
		}
		else {
			my $delay = 2 ** $i;
			wlog ERROR, "Connection failed for all addresses. Retrying in $delay seconds\n";
			select(undef, undef, undef, $delay);
		}
	}
	if (!$success) {
		die "Failed to connect: $!";
	}
	$LAST_HEARTBEAT = time();
}

sub initlog() {
        if (defined $ENV{"WORKER_LOGGING_ENABLED"}) {
		open(LOG, ">>$LOG") or die "Failed to open log file: $!";
		my $b = select(LOG);
		$| = 1;
		select($b);
		my $date = localtime;
		wlog INFO, "$BLOCKID Logging started: $date\n";
	}
	else {
		$LOGLEVEL = 999;
	}
}


sub init() {
        logsetup();
        reconnect();
}

sub logsetup() {
        my $schemes = join(", ", @SCHEME);
	my $hosts = join(", ", @HOSTNAME);
	my $ports = join(", ", @PORT);
	wlog DEBUG, "uri=$URISTR\n";
	wlog DEBUG, "scheme=$schemes\n";
	wlog DEBUG, "host=$hosts\n";
	wlog DEBUG, "port=$ports\n";
	wlog DEBUG, "blockid=$BLOCKID\n";
}

sub sendm {
	my ($tag, $flags, $msg) = @_;
	my $len = length($msg);
	my $buf = pack("VVV", $tag, $flags, $len);
	$buf = $buf.$msg;

	wlog(DEBUG, "OUT: len=$len, tag=$tag, flags=$flags\n");
	wlog(TRACE, "$msg\n");

	#($SOCK->send($buf) == length($buf)) || reconnect();
	$SOCK->blocking(1);
	eval {defined($SOCK->send($buf))} or wlog(WARN, "Send failed: $!\n") and die "Send failed: $!";
	#eval {defined($SOCK->send($buf))} or wlog(WARN, "Send failed: $!\n");
}

sub sendFrags {
	my ($tag, $flg, $data) = @_;
	
	my $flg2;
	my $msg;
	my $yield;
	if (defined($$data{"tag"})) {
		$tag = $$data{"tag"};
	}
	do {
		($flg2, $msg, $yield) = $$data{"nextData"}($data);
		sendm($tag, $flg | $flg2, $msg);
	} while (($flg2 & FINAL_FLAG) == 0 && !$yield);
	
	if (($flg2 & FINAL_FLAG) == 0) {
		# final flag not set; put it back in the queue
		wlog DEBUG, "$tag yielding\n";
		$$data{"tag"} = $tag;
		queueCmdCustomDataHandling($REPLIES{$tag}, $data);
	}
	else {
		if (exists($REPLIES{$tag})) {
			my $record = $REPLIES{$tag};
			my ($cont, $start) = ($$record[0], $$record[1]);
			if (defined($$cont{"dataSent"})) {
				$$cont{"dataSent"}($cont, $tag);
			}
		}
		wlog(DEBUG, "done sending frags for $tag\n");
	}
}

sub nextArrayData {
	my ($state) = @_;
	
	my $index = $$state{"index"};
	$$state{"index"} = $index + 1;
	my $data = $$state{"data"};
	if ($index > $#$data) {
		die "Index out of bounds";
	}
	return ($index >= $#$data ? FINAL_FLAG : 0, $$data[$index], CONTINUE);
}

sub arrayData {
	return {
		"index" => 0,
		"nextData" => \&nextArrayData,
		"data" => \@_
	};
}

sub nextFileData {
	my ($state) = @_;
	
	my $s = $$state{"state"};
	if ($s == 0) {
		$$state{"state"} = $s + 1;
		return (0, $$state{"cmd"}, CONTINUE);
	}
	elsif ($s == 1) {
		$$state{"state"} = $s + 1;
		return (0, pack("VV", $$state{"size"}, 0), CONTINUE);
	}
	elsif ($s == 2) {
		$$state{"state"} = $s + 1;
		return (0, $$state{"lname"}, CONTINUE);
	}
	elsif ($s == 3) {
		$$state{"state"} = $s + 1;
		$$state{"sent"} = 0;
		return ($$state{"size"} == 0 ? FINAL_FLAG : 0, $$state{"rname"}, CONTINUE);
	}
	else {
		my $handle = $$state{"handle"};
		my $buffer;
		my $sz = read($handle, $buffer, 8192);
		if (!defined $sz) {
			wlog INFO, "Failed to read data from file: $!\n";
			return (FINAL_FLAG + ERROR_FLAG, "$!", CONTINUE);
		}
		elsif ($sz == 0 && $$state{"sent"} < $$state{"size"}) {
			wlog INFO, "File size mismatch. $$state{'size'} vs. $$state{'sent'}\n";
			return (FINAL_FLAG + ERROR_FLAG, "File size mismatch. Expected $$state{'size'}, got $$state{'sent'}", CONTINUE);
		}
		$$state{"sent"} += $sz;
		wlog DEBUG, "size: $$state{'size'}, sent: $$state{'sent'}\n";
		if ($$state{"sent"} == $$state{"size"}) {
			close $handle;
		}
		return (($$state{"sent"} < $$state{"size"}) ? 0 : FINAL_FLAG, $buffer, YIELD);
	}
}

sub fileData {
	my ($cmd, $lname, $rname) = @_;
	
	my $desc;
	if (!open($desc, "<", "$lname")) {
		wlog WARN, "Failed to open $lname\n";
		# let it go on for now. The next read from the descriptor will fail	
	}
	return {
		"cmd" => $cmd,
		"state" => 0,
		"handle" => $desc,
		"nextData" => \&nextFileData,
		"size" => -s $lname,
		"lname" => $lname,
		"rname" => $rname
	};
}


sub sendCmdInt {
	my ($cont, $state) = @_;
	my $ctag = $$state{"tag"};
	if (!defined $ctag) {
		$ctag =  $TAG++;
		registerCmd($ctag, $cont);
	}
	sendFrags($ctag, 0, $state);
	return $ctag;
}

sub sendCmd {
	my @cmd = @_;
	my $cont = shift(@cmd);
	return sendCmdInt($cont, arrayData(@cmd));
}

sub queueCmd {
	my @cmd = @_;
	my $cont = shift(@cmd);
	push @CMDQ, [$cont, arrayData(@cmd)];
}

sub queueCmdCustomDataHandling {
	my ($cont, $state) = @_;
	push @CMDQ, [$cont, $state];
}

sub sendReply {
	my ($tag, @msgs) = @_;	
	sendFrags($tag, REPLY_FLAG, arrayData(@msgs));
}

sub sendError {
	my ($tag, @msgs) = @_;
	sendFrags($tag, REPLY_FLAG | ERROR_FLAG, arrayData(@msgs));
}

sub unpackData {
	my ($data) = @_;

	my $lendata = length($data);
	if ($lendata < 12) {
		wlog WARN, "Received faulty message (length < 12: $lendata)\n";
		die "Received faulty message (length < 12: $lendata)";
	}
	my $tag = unpack("V", substr($data, 0, 4));
	my $flg = unpack("V", substr($data, 4, 4));
	my $len = unpack("V", substr($data, 8, 4));
	my $msg;
	my $frag;
	my $alen = 0;
	while ($alen < $len) {
		$SOCK->recv($frag, $len - $alen);
		$alen = $alen + length($frag);
		$msg = $msg.$frag;
	}
	
	my $actuallen = length($msg);
	wlog(TRACE, " IN: len=$len, actuallen=$actuallen, tag=$tag, flags=$flg, $msg\n");
	if ($len != $actuallen) {
		wlog(WARN, "len != actuallen\n");
	}
	return ($tag, $flg, $msg);
}

sub processRequest {
	my ($state, $tag, $timeout, $err, $fin, $msg) = @_;
	
	my $request = $$state{"request"};
	if (!defined($request)) {
		$request = [];
		$$state{"request"} = $request;
	}
	push(@$request, $msg);
	
	if ($timeout) {
		sendError($tag, ("Timed out waiting for all fragments"));
	}
	elsif (!$fin) {
		return;
	}
	else {
		wlog DEBUG, "Processing request\n";
		my $cmd = shift(@$request);
		wlog DEBUG, "Cmd is $cmd\n";
		if (exists($HANDLERS{$cmd})) {
			$HANDLERS{$cmd}->($tag, 0, $request);
		}
		else {
			sendError($tag, ("Unknown command: $cmd"));
		}
	}
}

sub process {
	my ($tag, $flg, $msg) = @_;
	
	
	my $reply = $flg & REPLY_FLAG;
	my ($record, $cont, $start);
	
	if ($reply) {
		if (exists($REPLIES{$tag})) {
			$record = $REPLIES{$tag};
			($cont, $start) = ($$record[0], $$record[1]);
		}
		else {
			wlog(WARN, "received reply to unregistered command (tag=$tag). Discarding.\n");
			return;
		}
	}
	else {
		$LASTRECV = time();
		if (!exists($REQUESTS{$tag})) {
			$REQUESTS{$tag} = [{"dataIn" => \&processRequest}, time()];
			wlog DEBUG, "New request ($tag)\n";
		}
		$record = $REQUESTS{$tag};
		($cont, $start) = ($$record[0], $$record[1]);
	}
		
	my $fin = $flg & FINAL_FLAG;
	my $err = $flg & ERROR_FLAG;
		

	if ($fin) {
		if ($reply) {
			# A reply for a command sent by us has been received, which means that
			# the lifecycle of the command is complete, therefore the state of
			# that command can be deleted.
			delete($REPLIES{$tag});
		}
		else {
			# All fragments of a request have been received. Since the record is 
			# stored in $cont, $tag, $err, $fin, $msg, we can remove it from the
			# table of (partial) incoming requests
			delete($REQUESTS{$tag});
		}
		wlog DEBUG, "Fin flag set\n";
	}
	
	$$cont{"dataIn"}($cont, $tag, 0, $err, $fin, $msg);
	
	return 1;
}

sub checkTimeouts2 {
	my ($hash) = @_;
	
	my $now = time();
	my @del = ();
	
	my $k;
	my $v;
	
	while (($k, $v) = each(%$hash)) {
		if ($now - $$v[1] > REPLYTIMEOUT) {
			push(@del, $k);
			my $cont = $$v[0];
			$$cont{"dataIn"}($cont, $k, 1, 0, 0, "Reply timeout");
		}
	}
	
	foreach $k (@del) {
		delete $$hash{$k};
	}
}

my $LASTTIMEOUTCHECK = 0;

sub checkTimeouts {
	my $time = time();
	if ($time - $LASTTIMEOUTCHECK < 1) {
		return;
	}
	$LASTTIMEOUTCHECK = $time;
	checkTimeouts2(\%REQUESTS);
	checkTimeouts2(\%REPLIES);
	if ($LASTRECV != 0) {
		my $dif = $time - $LASTRECV;
		wlog TRACE, "time: $time, lastrecv: $LASTRECV, dif: $dif\n"; 
		if ($dif >= IDLETIMEOUT && $JOBS_RUNNING == 0) {
			wlog INFO, "Idle time exceeded (time=$time, LASTRECV=$LASTRECV, dif=$dif)\n";
			die "Idle time exceeded";
		}
	}
}

sub recvOne {
	my $data;
	$SOCK->blocking(0);
	$SOCK->recv($data, 12);
	if (length($data) > 0) {
		# wlog DEBUG, "Received " . unpackData($data) . "\n";
		eval { process(unpackData($data)); } || (wlog ERROR, "Failed to process data: $@\n" && die "Failed to process data: $@");
	}
	else {
		#sleep 1ms
		select(undef, undef, undef, 0.001);
		checkTimeouts();
	}
}

sub registerCmd {
	my ($tag, $cont) = @_;
	
	wlog DEBUG, "Replies: ".hts(\%REPLIES)."\n";
	
	$REPLIES{$tag} = [$cont, time(), ()];
}


sub mainloop {
	while(1) {
		loopOne();
	}
}

sub loopOne {
	my $cmd;
	if (time() - $LAST_HEARTBEAT > HEARTBEAT_INTERVAL) {
		queueCmd(heartbeatCB(), "HEARTBEAT");
		$LAST_HEARTBEAT = time();
	}
	# send whatever is now queued; don't clear the queue, since
	# things may be added to it while stuff is being sent
	my $sz = scalar(@CMDQ);
	for (my $i = 0; $i < $sz; $i++)  {
		$cmd = pop(@CMDQ);
		sendCmdInt(@$cmd);
	}
	checkJobs();
	recvOne();
}

sub printreply {
	my ($tag, $timeout, $err, $fin, $reply) = @_;
	if ($timeout) {
		wlog WARN, "Timed out waiting for reply to $tag\n";
	}
	else {
		wlog DEBUG, "$$reply[0]\n";
	}
}

sub nullCB {
	return {
		"dataIn" => sub {}
	};
}

sub registerCB {
	return {
		"dataIn" => \&registerCBDataIn
	};
}

sub registerCBDataIn {
	my ($state, $tag, $timeout, $err, $fin, $reply) = @_;
	
	if ($timeout) {
		die "Failed to register (timeout)\n";
	}
	elsif ($err) {
		die "Failed to register (service returned error: ".join("\n", $reply).")";
	}
	else {
		$ID = $reply;
		wlog INFO, "Registration successful. ID=$ID\n";
	}
}

sub heartbeatCB {
	return {
		"dataIn" => \&heartbeatCBDataIn
	};
}

sub heartbeatCBDataIn {
	my ($state, $tag, $timeout, $err, $fin, $reply) = @_;
	
	if ($timeout) {
		if (time() - $LAST_HEARTBEAT > 2 * HEARTBEAT_INTERVAL) {
			wlog WARN, "No heartbeat replies in a while. Dying.\n";
			die "No response to heartbeat\n";
		}
	}
	elsif ($err) {
		wlog WARN, "Heartbeat failed: $reply\n";
		die "Heartbeat failed: $reply\n";
	} 
	else {
		wlog DEBUG, "Heartbeat acknowledged\n";
	}
}


sub register {
	my ($tag, $timeout, $reply) = @_;
	sendReply($tag, ("OK"));
}


sub shutdownw {
	my ($tag, $timeout, $msgs) = @_;
	wlog DEBUG, "Shutdown command received\n";
	sendReply($tag, ("OK"));
	select(undef, undef, undef, 1);
	wlog INFO, "Acknowledged shutdown. Exiting\n";
	wlog INFO, "Ran a total of $JOB_COUNT jobs\n";
	exit 0;
}

sub heartbeat {
	my ($tag, $timeout, $msgs) = @_;
	sendReply($tag, ("OK"));
}

sub workershellcmd {
	my ($tag, $timeout, $msgs) = @_;
	my $cmd = $$msgs[1];
	my $out;
	if ($cmd =~ m/cd\s*(.*)/) {
		wlog DEBUG, "chdir $1\n";
		chdir $1;
		if ($! ne '') {
			sendError($tag, ("$!"));
		}
		else {
			sendReply($tag, ("OK", ""));
		}
	}
	elsif ($cmd =~ m/mls\s*(.*)/) {
		wlog DEBUG, "mls $1\n";
		$out = `ls -d $1 2>/dev/null`;
		sendReply($tag, ("OK", "$out"));
	}
	else {
		$out = `$cmd 2>&1`;
		sendReply($tag, ("OK", "$out"));
	}
}

sub urisplit {
	my ($name) = @_;

	if (index($name, ":") == -1) {
		return ("file", $name);
	}

	my ($protocol, $path) = split(/:\/\//, $name, 2);

	return ($protocol, $path);
}

sub getFileCB {
	my ($jobid, $src, $dst) = @_;
	
	my ($protocol, $path) = urisplit($src);
	wlog DEBUG, "$jobid src: $src, protocol: $protocol, path: $path\n";
	
	if (($protocol eq "file") || ($protocol eq "proxy")) {
		wlog DEBUG, "Opening $dst...\n";
		my $dir = dirname($dst);
		if (-f $dir) {
			die "$jobid Cannot create directory $dir. A file with this name already exists";
		}
		if (!-d $dir) {
			if (!mkpath($dir)) {
				die "Cannot create directory $dir. $!";
			}
		}
		# don't try open(DESC, ...) (as I did). It will use the same reference 
		# and concurrent operations will fail. 
		my $desc;
		if (!open($desc, ">", "$dst")) {
			die "Failed to open $dst: $!";
		}
		else {
			wlog DEBUG, "$jobid Opened $dst\n";
			return {
				"jobid" => $jobid,
				"dataIn" => \&getFileCBDataIn,
				"state" => 0,
				"lfile" => $dst,
				"desc" => $desc
			};
		}
	}
	else {
		return {
			"jobid" => $jobid,
			"dataIn" => \&getFileCBDataInIndirect,
			"lfile" => $dst,
		};
	}
}

sub getFileCBDataInIndirect {
	my ($state, $tag, $timeout, $err, $fin, $reply) = @_;
	
	my $jobid = $$state{"jobid"};
	wlog DEBUG, "$jobid getFileCBDataInIndirect jobid: $jobid, tag: $tag, err: $err, fin: $fin\n";
	if ($err) {
		queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "520", "Error staging in file: $reply"));
		delete($JOBDATA{$jobid});
		return;
	}
	elsif ($timeout) {
		queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "521", "Timeout staging in file"));
		delete($JOBDATA{$jobid});
		return;
	}
	if ($fin) {
		stagein($jobid);
	}
}


sub getFileCBDataIn {
	my ($state, $tag, $timeout, $err, $fin, $reply) = @_;
	
	my $s = $$state{"state"};
	my $jobid = $$state{"jobid"};
	wlog DEBUG, "$jobid getFileCBDataIn jobid: $jobid, state: $s, tag: $tag, err: $err, fin: $fin\n";
	if ($err) {
		queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "520", "Error staging in file: $reply"));
		delete($JOBDATA{$jobid});
		return;
	}
	elsif ($timeout) {
		queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "521", "Timeout staging in file"));
		delete($JOBDATA{$jobid});
		return;
	}
	elsif ($s == 0) {
		$$state{"state"} = 1;
		$$state{"size"} = unpack("V", $reply);
		my $lfile = $$state{"lfile"};
	}
	else {
		my $desc = $$state{"desc"};
		if (!(print {$desc} $reply)) {
			close $desc;
			wlog DEBUG, "$jobid Could not write to file: $!. Descriptor was $desc; lfile: $$state{'lfile'}\n"; 
			queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "522", "Could not write to file: $!"));
			delete($JOBDATA{$jobid});
			return;
		}
	}
	if ($fin) {
		my $desc = $$state{"desc"};
		close $desc;
		wlog DEBUG, "$jobid Closed $$state{'lfile'}\n";
		stagein($jobid);
	}
}

sub stagein {
	my ($jobid) = @_;
	
	my $STAGE = $JOBDATA{$jobid}{"stagein"};
	my $STAGED = $JOBDATA{$jobid}{"stageind"}; 
	my $STAGEINDEX = $JOBDATA{$jobid}{"stageindex"};
	
	if (scalar @$STAGE <= $STAGEINDEX) {
		wlog DEBUG, "$jobid Done staging in files ($STAGEINDEX, $STAGE)\n";
		$JOBDATA{$jobid}{"stageindex"} = 0;
		sendCmd((nullCB(), "JOBSTATUS", $jobid, ACTIVE, "0", "workerid=$ID"));
		forkjob($jobid);
	}
	else {
		if ($STAGEINDEX == 0) {
			sendCmd((nullCB(), "JOBSTATUS", $jobid, STAGEIN, "0", "workerid=$ID"));
		}
		wlog DEBUG, "$jobid Staging in $$STAGE[$STAGEINDEX]\n";
		$JOBDATA{$jobid}{"stageindex"} =  $STAGEINDEX + 1;
		my ($protocol, $path) = urisplit($$STAGE[$STAGEINDEX]);
		if ($protocol eq "sfs") {
			if (!copy($path, $$STAGED[$STAGEINDEX])) {
				wlog DEBUG, "$jobid Error staging in $path: $!\n";
				queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "524", "$@"));
			}
			else {
				stagein($jobid);		
			}
		}
		else {
			my $state;
			eval {
				$state = getFileCB($jobid, $$STAGE[$STAGEINDEX], $$STAGED[$STAGEINDEX]);
			};
			if ($@) {
				wlog DEBUG, "$jobid Error staging in file: $@\n";
				queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "524", "$@"));	
			}
			else {
				sendCmd(($state, "GET", $$STAGE[$STAGEINDEX], $$STAGED[$STAGEINDEX]));
			}
		}
	}
}


sub stageout {
	my ($jobid) = @_;
	
	wlog DEBUG, "$jobid Staging out\n";
	my $STAGE = $JOBDATA{$jobid}{"stageout"};
	my $STAGED = $JOBDATA{$jobid}{"stageoutd"}; 
	my $STAGEINDEX = $JOBDATA{$jobid}{"stageindex"};
	
	my $sz = scalar @$STAGE;
	wlog DEBUG, "sz: $sz, STAGEINDEX: $STAGEINDEX\n";
	if (scalar @$STAGE <= $STAGEINDEX) {
		$JOBDATA{$jobid}{"stageindex"} = 0;
		wlog DEBUG, "$jobid No more stageouts. Doing cleanup.\n";
		cleanup($jobid);
	}
	else {
		my $lfile = $$STAGE[$STAGEINDEX];
		if (-e $lfile) {
			if ($STAGEINDEX == 0) {
				wlog DEBUG, "$jobid Sending STAGEOUT status\n";
				sendCmd((nullCB(), "JOBSTATUS", $jobid, STAGEOUT, "0", "workerid=$ID"));
			}
			my $rfile = $$STAGED[$STAGEINDEX];
			$JOBDATA{$jobid}{"stageindex"} = $STAGEINDEX + 1;
			wlog DEBUG, "$jobid Staging out $lfile.\n";
			my ($protocol, $path) = urisplit($rfile);
			if ($protocol eq "file" || $protocol eq "proxy") {
				queueCmdCustomDataHandling(putFileCB($jobid), fileData("PUT", $lfile, $rfile));
			}
			elsif ($protocol eq "sfs") {
				if (!copy($lfile, $path)) {
					queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "528", "$!"));
					return;
				}
				else {
					stageout($jobid);
				}
			}
			else {
				queueCmd((putFileCB($jobid), "PUT", pack("VV", 0, 0), $lfile, $rfile));
			}
			wlog DEBUG, "$jobid PUT sent.\n";
		}
		else {
			wlog INFO, "$jobid Skipping stageout of missing file ($lfile)\n";
			$JOBDATA{$jobid}{"stageindex"} = $STAGEINDEX + 1;
			stageout($jobid);
		}
	}
}

sub cleanup {
	my ($jobid) = @_;
	
	my $ec = $JOBDATA{$jobid}{"exitcode"};
	if (ASYNC) {
		if ($ec == 0) {
			queueCmd((nullCB(), "JOBSTATUS", $jobid, COMPLETED, "0", ""));
		}
		else {
			queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "$ec", "Job failed with an exit code of $ec"));
		}
	}
	
	if ($ec != 0) {
		wlog DEBUG, "$jobid Job data: ".hts($JOBDATA{$jobid})."\n";
		wlog DEBUG, "$jobid Job: ".hts($JOBDATA{$jobid}{'job'})."\n";
		wlog DEBUG, "$jobid Job dir ".`ls -al $JOBDATA{$jobid}{'job'}{'directory'}`."\n";
	}
	
	my $CLEANUP = $JOBDATA{$jobid}{"cleanup"};
	my $c;
	if ($ec == 0) {
		for $c (@$CLEANUP) {
			if ($c =~ /\/\.$/) {
				chop $c;
				chop $c;
			}
			wlog DEBUG, "$jobid Removing $c\n";
			rmtree($c, {safe => 1, verbose => 0});
			wlog DEBUG, "$jobid Removed $c\n";
		}
	}
	
	if (!ASYNC) {
		if ($ec == 0) {
			queueCmd((nullCB(), "JOBSTATUS", $jobid, COMPLETED, "0", ""));
		}
		else {
			wlog DEBUG, "$jobid Sending failure.\n";
			queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "$ec", "Job failed with and exit code of $ec"));
		}
	}
}

sub putFileCB {
	my ($jobid) = @_;
	return {
		"jobid" => $jobid,
		"dataIn" => \&putFileCBDataIn,
		"dataSent" => \&putFileCBDataSent
	};
}

sub putFileCBDataSent {
	my ($state, $tag) = @_;
	
	if (ASYNC) {
		wlog DEBUG, "putFileCBDataSent\n";
		my $jobid = $$state{"jobid"};
		if ($jobid != -1) {
			wlog DEBUG, "Data sent, async is on. Staging out next file\n";
			stageout($jobid);
		}
	}
}

sub putFileCBDataIn {
	my ($state, $tag, $timeout, $err, $fin, $reply) = @_;
	
	wlog DEBUG, "putFileCBDataIn: $reply\n";
	
	my $jobid = $$state{"jobid"};
	
	if ($err || $timeout) {
		if ($JOBDATA{$jobid}) {
			wlog DEBUG, "Stage out failed ($reply)\n";
			queueCmd((nullCB(), "JOBSTATUS", $jobid, FAILED, "515", "Stage out failed ($reply)"));
			delete($JOBDATA{$jobid});
		}
		return;
	}
	elsif ($jobid != -1) {
		if (!ASYNC) {
			wlog DEBUG, "Stageout done; staging out next file\n";
			stageout($jobid);
		}
	}
}

sub isabsolute {
	my ($fn) = @_;
	
	return substr($fn, 0, 1) eq "/";
}


sub submitjob {
	my ($tag, $timeout, $msgs) = @_;
	my $desc = $$msgs[0];
	my @lines = split(/\n/, $desc);
	my $line;
	my $JOBID = undef;
	my %JOB = ();
	my @JOBARGS = ();
	my %JOBENV = ();
	my @STAGEIN = ();
	my @STAGEIND = ();
	my @STAGEOUT = ();
	my @STAGEOUTD = ();
	my @CLEANUP = ();
	foreach $line (@lines) {
		$line =~ s/\\n/\n/;
		$line =~ s/\\\\/\\/;
		my @pair = split(/=/, $line, 2);
		if ($pair[0] eq "arg") {
			push @JOBARGS, $pair[1];
		}
		elsif ($pair[0] eq "env") {
			my @ep = split(/=/, $pair[1], 2);
			$JOBENV{"$ep[0]"} = $ep[1];
		}
		elsif ($pair[0] eq "identity") {
			$JOBID = $pair[1];
		}
		elsif ($pair[0] eq "stagein") {
			my @pp = split(/\n/, $pair[1], 2);
			push @STAGEIN, $pp[0];
			if (isabsolute($pp[1])) {
				push @STAGEIND, $pp[1];
			}
			else {
				# there's the assumption here that the directory is sent before
				# the stagein/out data.
				push @STAGEIND, $JOB{directory}."/".$pp[1];
			}
		}
		elsif ($pair[0] eq "stageout") {
			my @pp = split(/\n/, $pair[1], 2);
			if (isabsolute($pp[0])) {
				push @STAGEOUT, $pp[0];
			}
			else {
				push @STAGEOUT, $JOB{directory}."/".$pp[0];
			}
			push @STAGEOUTD, $pp[1];
		}
		elsif ($pair[0] eq "cleanup") {
			if (isabsolute($pair[1])) {
				push @CLEANUP, $pair[1];
			}
			else {
				push @CLEANUP, $JOB{directory}."/".$pair[1];
			}
		}
		else {
			$JOB{$pair[0]} = $pair[1];
		}
	}
	if (checkJob($tag, $JOBID, \%JOB)) {
		$JOBDATA{$JOBID} = {
			stagein => \@STAGEIN,
			stageind => \@STAGEIND,
			stageindex => 0,
			job => \%JOB,
			jobargs => \@JOBARGS,
			jobenv => \%JOBENV,
			stageout => \@STAGEOUT,
			stageoutd => \@STAGEOUTD,
			cleanup => \@CLEANUP,
		};
		
		stagein($JOBID);
	}
}

sub checkJob() {
	my ($tag, $JOBID, $JOB) = @_;
	
	wlog INFO, "$JOBID Job info received (tag=$tag)\n";
	my $executable = $$JOB{"executable"};
	if (!(defined $JOBID)) {
		my $ds = hts($JOB);
		
		wlog DEBUG, "$JOBID Job details $ds\n";
		
		sendError($tag, ("Missing job identity"));
		return 0;
	}
	elsif (!(defined $executable)) {
		sendError($tag, ("Missing executable"));
		return 0;
	}
	else {
		my $dir = $$JOB{directory};
		if (!defined $dir) {
			$dir = ".";
		}
		my $dirlen = length($dir);
		my $cleanup = $$JOB{"cleanup"};
		my $c;
		foreach $c (@$cleanup) {
			if (substr($c, 0, $dirlen) ne $dir) {
				sendError($tag, ("Cannot clean up outside of the job directory (cleanup: $c, jobdir: $dir)"));
				return 0;
			}
		}
		chdir $dir;
		wlog DEBUG, "$JOBID Job check ok (dir: $dir)\n";
		wlog INFO, "$JOBID Sending submit reply (tag=$tag)\n";
		sendReply($tag, ("OK"));
		wlog INFO, "$JOBID Submit reply sent (tag=$tag)\n";
		return 1;
	}
}

sub forkjob {
	my ($JOBID) = @_;
	my ($pid, $status);
	
	my $JOB = $JOBDATA{$JOBID}{"job"};
	my $JOBARGS = $JOBDATA{$JOBID}{"jobargs"};
	my $JOBENV = $JOBDATA{$JOBID}{"jobenv"};
	
	pipe(PARENT_R, CHILD_W);
	$pid = fork();
	if (defined($pid)) {
		if ($pid == 0) {
			close PARENT_R;
			runjob(\*CHILD_W, $JOB, $JOBARGS, $JOBENV);
			close CHILD_W;
		}
		else {
			wlog DEBUG, "$JOBID Forked process $pid. Waiting for its completion\n";
			close CHILD_W;
			$JOBS_RUNNING++;
			$JOBWAITDATA{$JOBID} = {
				pid => $pid,
				pipe => \*PARENT_R
			};
		}
	}
	else {
		queueCmd(nullCB(), "JOBSTATUS", $JOBID, FAILED, "512", "Could not fork child process");
	}
	$LASTRECV = time();
}

my $LASTJOBCHECK = 0;

sub checkJobs {
	my $time = time();
	if ($time - $LASTJOBCHECK < 0.100) {
		return;
	}
	$LASTJOBCHECK = $time;
	if (!%JOBWAITDATA) {
		return;
	}
	
	wlog DEBUG, "Checking jobs status ($JOBS_RUNNING active)\n";
	
	my @DELETEIDS = ();
	 
	for my $JOBID (keys %JOBWAITDATA) {
		if (checkJobStatus($JOBID)) {
			push @DELETEIDS, $JOBID;
		}
	}
	for my $i (@DELETEIDS) {
		delete $JOBWAITDATA{$i};
	}
}

sub checkJobStatus {
	my ($JOBID) = @_;
	
	
	my $pid = $JOBWAITDATA{$JOBID}{"pid"};
	my $RD = $JOBWAITDATA{$JOBID}{"pipe"};
	
	my $tid;
	my $status;
	
	wlog DEBUG, "$JOBID Checking pid $pid\n";
	
	$tid = waitpid($pid, &WNOHANG);
	if ($tid != $pid) {
		# not done
		wlog DEBUG, "$JOBID Job $pid still running\n";
		return 0;
	}
	else {
		# exit code is in MSB and signal in LSB, so
		# switch them such that status & 0xff is the
		# exit code
		$status = $? >> 8 + (($? & 0xff) << 8);
	}

	wlog DEBUG, "$JOBID Child process $pid terminated. Status is $status.\n";
	my $s;
	if (!eof($RD)) {
		$s = <$RD>;
	}
	wlog DEBUG, "$JOBID Got output from child. Closing pipe.\n";
	close $RD;
	$JOBDATA{$JOBID}{"exitcode"} = $status;
	if (defined $s) {
		queueCmd(nullCB(), "JOBSTATUS", $JOBID, FAILED, "$status", $s);
	}
	else {
		#queueCmd(nullCB(), "JOBSTATUS", $JOBID, COMPLETED, "$status", "");
		stageout($JOBID);
	}
	$JOB_COUNT++;
	$JOBS_RUNNING--;
	return 1;
}

sub runjob {
	my ($WR, $JOB, $JOBARGS, $JOBENV) = @_;
	my $executable = $$JOB{"executable"};
	my $stdout = $$JOB{"stdout"};
	my $stderr = $$JOB{"stderr"};

	my $cwd = getcwd();
	wlog DEBUG, "CWD: $cwd\n";
	wlog DEBUG, "Running $executable\n";
	if (defined $$JOB{directory}) {
		wlog DEBUG, "Directory: $$JOB{directory}\n";
	}
	my $ename;
	foreach $ename (keys %$JOBENV) {
		$ENV{$ename} = $$JOBENV{$ename};
	}
	wlog DEBUG, "Command: @$JOBARGS\n";
	unshift @$JOBARGS, $executable;
	if (defined $$JOB{directory}) {
	    chdir $$JOB{directory};
	}
	if (defined $stdout) {
		wlog DEBUG, "STDOUT: $stdout\n";
		close STDOUT;
		open STDOUT, ">$stdout" or die "Cannot redirect STDOUT";
	}
	if (defined $stderr) {
		wlog DEBUG, "STDERR: $stderr\n";
		close STDERR;
		open STDERR, ">$stderr" or die "Cannot redirect STDERR";
	}
	close STDIN;
	wlog DEBUG, "Command: @$JOBARGS\n";
	exec { $executable } @$JOBARGS or print $WR "Could not execute $executable: $!\n";
	die "Could not execute $executable: $!";
}

initlog();

my $MSG="0";

my $myhost=`hostname`;
$myhost =~ s/\s+$//;

wlog(INFO, "Running on node $myhost\n");
# wlog(INFO, "New log name: $LOGNEW \n");

init();

mainloop();
wlog INFO, "Worker finished. Exiting.\n";
exit(0);

# Local Variables:
# indent-tabs-mode: t
# tab-width: 8
# perl-indent-level: 8
# End: