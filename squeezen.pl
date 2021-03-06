#!/usr/bin/perl
use strict;
no warnings;
use Curses;
use Curses::UI 0.9608;
use URI::Escape qw(uri_escape uri_unescape);
use IO::Socket::INET;
use IO::Select;
use Socket qw(SOCK_STREAM inet_ntoa);

my $host;
my $player;

my %config;
%config = (%config, do { my @c = do $_; die $@ if $@; @c } ) for grep -e,
    "/etc/squeezenrc",
    "$ENV{HOME}/.squeezenrc",
    "./.squeezenrc";

$host   = delete $config{host}   if exists $config{host};
$player = delete $config{player} if exists $config{player};

my $ui = Curses::UI->new(-compat => 1, -color_support => 1);
my $window = $ui->add(undef,  'Window');
my $in_modal = 0;

{
    my $socket;
    sub squeeze {
        my @args = @_;
        $_ = uri_escape($_) for @args;

        $socket && $socket->connected or $socket = IO::Socket::INET->new(
            PeerHost => "$host:9090",
            Type => SOCK_STREAM,
        ) or return;

        $socket->print("@args\n");
        my @reply = split " ", readline $socket;
        $_ = uri_unescape($_) for @reply;
        return @reply;
    }
}

sub group {
    my $firstkey = shift;
    my $returncommon = $firstkey =~ s/^-//;
    my $common;
    my @items;
    while (defined (my $input = shift)) {
        if ($input =~ /:/) {
            my ($key, $value) = split /:/, $input, 2;
            $key =~ s/ /_/g;
            if ($key eq $firstkey) {
                push @items, { $key => $value };
            } elsif (@items) {
                $items[-1]{ $key } = $value;
            } else {
                $common->{ $key } = $value;
            }
        } else {
            push @{ $common->{_} }, $_;
        }
    }
    return $common, @items if $returncommon;
    return @items;
}

sub ftime {
    my ($s) = @_;
    $s //= 0;
    my $m = int($s / 60);
    $s %= 60;
    return sprintf "%d:%02d", $m, $s;
}

if (not $host) {
    my $send = IO::Socket::INET->new(
        PeerAddr => "255.255.255.255",
        PeerPort => 3483,
        Proto => 'udp',
        Broadcast => 1,
        Reuse => 1,
    ) or die "Can't open broadcast socket ($!)";
    my $receive = IO::Socket::INET->new(
        LocalAddr => "0.0.0.0",
        LocalPort => $send->sockport,
        Proto => 'udp',
        Reuse => 1,
    );

    # "TLV" discovery, per Slim::Networking::Discovery
    my $select = IO::Select->new;
    $select->add($receive);
    $send->send("e") or die $!;
    my $buf;
    if ($select->can_read(2) && $receive->recv($buf, 1)) {
        $host = $receive->peerhost;
    }
    $host or die "No server found";
}

if (not $player) {
    my @players = group playerindex => squeeze qw'players 0 100'
        or die "No players found";
    if (@players == 1) {
        $player = $players[0]{playerid};
    } else {
        my $list;
        $list = $window->add("pickplayer", "Listbox",
            -title => "Pick a player",
            -border => 1,
            -values => [ 0..$#players ],
            -labels => { map { ($_ => $players[$_]{name}) } 0..$#players },
            -onchange => sub {
                $player = $players[ shift->get ]->{playerid};
                $window->delete("pickplayer");
                $ui->mainloopExit();
            }
        );
        $ui->mainloop();
    }
}

if (@ARGV) {
    $ARGV[0] = $player if $ARGV[0] eq 'P';
    print "$_\n" for squeeze @ARGV;
    exit;
}


sub prev      { squeeze $player, qw'playlist index -1' }
sub next      { squeeze $player, qw'playlist index +1' }
sub playpause { squeeze $player, qw'pause' }
sub jump      { squeeze $player, qw'playlist index', (split /~/, shift->get)[0] }
sub volup     { squeeze $player, qw'mixer volume +2.5'; update_status(); }
sub voldown   { squeeze $player, qw'mixer volume -2.5'; update_status(); }
sub vol       { squeeze $player, qw'mixer volume', shift; update_status(); }
sub mute      { squeeze $player, qw'mixer muting'; update_status(); }

sub delete    {
    my ($playlist) = @_;
    squeeze $player,qw'playlist delete', $playlist->get_active_value;
    update_status();
}

my $current_folder;
my $bdialog;
sub browser_go {
    my ($browser, $action) = @_;
    my $pick = $browser->get || "";
    if ($action and $action eq "GO_BACK") {
        $pick = $browser->{__back} or return;
    }
    my $ypos;
    if ($pick =~ s/!(\d+)$//) {
        $ypos = $1;
    }
    if ($pick eq 'MIX') {
        squeeze $player, qw'randomplay tracks';
        update_status();
        $browser->clear_selection();
    } elsif ($pick eq 'CLEAR') {
        squeeze $player, qw'playlist clear';
        update_status();
        $browser->clear_selection();
    } elsif ($pick =~ /^folder~(.*)/) {
        my @path = split /\D/, $1;
        my @up = @path > 1 ? @path[0 .. ($#path - 1)] : ();

        my $fid = $path[-1];

        my %finfo = map { split /:/, $_, 2 } grep /:/,
            squeeze qw'musicfolder 0 1 return_top:1', "folder_id:$fid";

        my %parent = @up
            ? (
                map { split /:/, $_, 2 } grep /:/,
                squeeze qw'musicfolder 0 1 return_top:1', "folder_id:$up[-1]"
            )
            : ();

        my @folder =
        my @items = group id => squeeze qw'musicfolder 0 2000 tags:at',
            "folder_id:$fid";

        my $y = $browser->{-ypos};
        my $values = [ "HOME", (@up ? "folder~@up!$y" : ()), map {
            "$_->{type}~@path~$_->{id}"
        } @items ];
        my $labels = { "HOME" => "== Home ==", (@up ? ("folder~@up!$y" => "<- $parent{filename}") : ()),
        map { ("$_->{type}~@path~$_->{id}" => $_->{filename}) } @items };
        $browser->{__back} = @up ? "folder~@up!$y" : "HOME";
        $browser->title($finfo{filename});
        $browser->values($values);
        $browser->labels($labels);
        $browser->{-ypos} = $ypos // 1;
        $browser->draw();

        $current_folder = $fid;
    } elsif ($pick =~ /^(PLAY|ADD|INSERT)(?:~(\d))?~(\d+)/) {
        my $command = lc $1;
        my $skip = $2;
        my $id = $3;
        my $url = (grep /^url:/,
            squeeze qw'songinfo 0 100 tags:u', "track_id:$id")[0];
        $url =~ s/^url://;

        squeeze $player, qw'playlist', $command, $url;
        squeeze $player, qw'playlist index +1' if $skip;
        browser_go($browser, 'GO_BACK');
    } elsif ($pick =~ /~(\d+)$/) {
        my $id = $1;

        # Oh, this is so ugly.
        $pick =~ s///;
        $pick =~ s/^\w+/folder/;
        my $y = $browser->{-ypos};
        $browser->{__back} = "$pick!$y";

        $browser->title("What do you want me to do?");
        $browser->values([ "INSERT~1~$id", "INSERT~0~$id", "ADD~$id", "PLAY~$id", "$pick!$y" ]);
        $browser->labels({
            "INSERT~1~$id" => "Add to TOP of playlist and SKIP right to it",
            "INSERT~0~$id" => "Add to TOP of playlist",
            "ADD~$id" => "Add to BOTTOM of playlist",
            "PLAY~$id" => "Start new playlist with this song",
            "$pick!$y" => "<- Never mind",
        });
        $browser->draw();
    } else {
        $browser->title("Browser");
        $browser->values([ qw/MIX folder~0 CLEAR/ ]);
        $browser->labels({
            CLEAR => "Clear playlist",
            MIX => "Party mix",
            'folder~0' => "Browse music folder",
        });
        $browser->draw();
    }
}


sub help {
    $in_modal = 1;
    $ui->dialog(-title => "Help", -message => q{
    ? h             Help
    q               Quit

    Tab Enter ...   The usual GUI stuff

    + =             Volume louder
    -               Volume softer
    1 2 3 ... 0     Volume
    m `             Mute

    < ,             Previous
    p \ |           Play / Pause
    > .             Next
    });
    $in_modal = 0;
}

my %keys = (
    'h' => \&help,
    '?' => \&help,
    'q' => sub { exit },
    '+' => \&volup,
    '=' => \&volup,
    '-' => \&voldown,
    'p' => \&playpause,
    '\\' => \&playpause,
    '|' => \&playpause,
    '<' => \&prev,
    '>' => \&next,
    ',' => \&prev,
    '.' => \&next,
    '`' => \&mute,
    'm' => \&mute,
    '1' => sub { vol  10 },
    '2' => sub { vol  20 },
    '3' => sub { vol  30 },
    '4' => sub { vol  40 },
    '5' => sub { vol  50 },
    '6' => sub { vol  60 },
    '7' => sub { vol  70 },
    '8' => sub { vol  80 },
    '9' => sub { vol  90 },
    '0' => sub { vol 100 },
);
$ui->set_binding($keys{$_}, $_) for keys %keys;

my $title;
my $controls = $window->add(undef, 'Container',
    -releasefocus => 1,
    -x => 0,
    -border => 0,
    -height => 2,
    -titlereverse => 0,
    -onfocus => sub { $title->bold(1) },
    -onblur  => sub { $title->bold(0) },
);
$title = $controls->add(undef, 'Label', -y => 0, -underline => 1 );

my $buttons = [
    { -label => ' |<< ', -onpress => \&prev },
    { -label => ' PP ', -onpress => \&playpause },
    { -label => ' >>| ', -onpress => \&next },
];
my $time = $controls->add(undef, 'Label', -width => 14, -y => 1, -x => 1 );

$controls->add(undef, 'Buttonbox',
    -y => 1,
    -x => 40,
    -width => 16,
    -buttons => $buttons
);
my $volume = $controls->add(undef, 'Label', -y => 1,  -x => 67 );

my $playlist = $window->add(undef, 'Listbox',
    -border => 1,
    -height => 10,
    -y => 2,
    -title => "Playlist",
    -titlereverse => 0,
    -onchange => \&jump,
    -vscrollbar => 'right',
);
$playlist->set_binding(\&delete, KEY_DC());

my $browser = $window->add(undef, 'Listbox',
    -y => 12,
    -border => 1,
    -height => 10,
    -titlereverse => 0,
    -onchange => \&browser_go,
    -vscrollbar => 'right',
);
$browser->set_binding(sub {
    browser_go($browser, "GO_BACK");
}, KEY_LEFT());


$controls->set_binding(sub { $browser->focus }, KEY_BTAB);
$controls->set_binding(sub { $playlist->focus }, "\t");

browser_go($browser);
update_status();

$ui->set_timer(1, sub {
    update_status()
});

$ui->mainloop;

#  meh, globals :)

sub update_status {
    my ($status, @plist) = group -playlist_index => squeeze $player,
        qw'status - 50';

    my $t = ftime($status->{time}) . ' / ' . ftime($status->{duration});
    $time->text($t);

    $status->{mixer_volume} //= 0;
    my $v = $status->{mixer_volume} > 0
        ? sprintf "Volume %3d%%", int($status->{mixer_volume})
        : sprintf "%11s", "* MUTE *";
    $volume->text($v);

    $status->{mode} //= 'pause';
    $buttons->[1]{-label} = $status->{mode} eq 'play' ? ' || ' : ' >  ';

    my $np = (grep { $_->{playlist_index} == $status->{playlist_cur_index} } @plist)[0];
    my $w = $title->width;
    $np = $np ? "$np->{artist} - $np->{title}" : "Silence";
    $title->text(sprintf "%-${w}s", " $np");

    my $ypos = $playlist->{-ypos};
    (undef, my $song_id) = split /~/, $playlist->get_active_value // "~-1";
    unless ($in_modal) {
        for (0..$#plist) {
            $ypos = $_ if $plist[$_]->{id} == $song_id;
        }
        $playlist->values(
            [ map "$_->{playlist_index}~$_->{id}", @plist ]
        );
        $playlist->labels( { map {
            ("$_->{playlist_index}~$_->{id}" => "$_->{artist} - $_->{title}")
        } @plist });
        $playlist->{-ypos} = $ypos;
        $playlist->draw();
    }
}
