#!/usr/bin/perl
use warnings;
use strict;
use File::Find;
use Getopt::Long;
use Data::Dumper;
use Term::ANSIColor;
use File::Copy;
use Cwd;


# depends: shntools cuetools eyed3

# GLOBALS
our %opt;
our %skip;

our $SHNSPLIT_PREFIX = "split-track";
our $LAME_PATH = "lame";
our @LAME_OPTS = qw/-q0 -V2/;
our $MPPDEC = "/home/piotr/bin/mppdec-static";
our $MAC_PATH = "/home/piotr/bin/mac";




sub ask_yes
{
    print join(' ',@_)." [Y/n] ";
    while(my $in = <STDIN>) {
        if( $in=~/^y$/i ) {
            print "\n";
            return 1;
        } elsif($in=~ /^n$/i ) {
            print "\n";
            return 0;
        } else {
            print join(' ',@_)." [Y/n] ";
        }
    }
}

sub delete_wav_mp3
{
    my $prefix = $_[0];
    if( -f $prefix.".wav" ) {
        if(ask_yes(color("red")."Delete".color("reset")." $prefix.wav ?")) {
            unlink($prefix.".wav");
        }
    }
    if( -f $prefix.".mp3") {
        if(ask_yes(color("red")."Delete".color("reset")." $prefix.mp3 ?")) {
            unlink($prefix.".mp3");
        }
    }
}

sub system_failed
{
    my $cmd = shift;
    print_errors();
    die "execution of:\"".join(" ",@$cmd)."\" failed: $!";
}

sub cue_parse
{
    my $file = shift or return undef;
    my $cue = {};
    my $track;
    my $trck=0;
    open(CUE,'<',$file) or die "open: $!";
    while(<CUE>) {
        if($track && m/PERFORMER ["']([^"']+)["']/i ) {
            $cue->{TRACK}{$track}{PERFORMER} = $1;
            next;
        }
        if($track && m/TITLE ["']([^"']+)["']/i ) {
            $cue->{TRACK}{$track}{TITLE} = $1;
            next;
        }

        if(m/PERFORMER ["']([^"']+)["']/i ) {
            $cue->{PERFORMER} = $1;
            next;
        }
        if(m/TITLE ["']([^"']+)["']/i ) {
            $cue->{TITLE} = $1;
            next;
        }
        if(m/FILE ["']([^"']+)["'] (.+)/i ) {
            $cue->{FILE} = $1;
            $cue->{FILE_TYPE} = $2;
            warn "format not WAVE" if ($2 !~ m/WAVE/i);
            next;
        }
        if(m/TRACK (\d{1,2}) AUDIO/) {
            $track = $1;
            $cue->{TRACK}{$track} = {};
            next;
        }
    }
    close(CUE);
    #print Dumper($cue);
    return $cue if $cue->{FILE};
}

sub cue_process
{
    my $cue = shift || return;
    my $cuefile = shift || return;

    local $SIG{PIPE} = sub { die "broken pipe" };
    open(CUEBRK,"-|","cuebreakpoints",$cuefile) or die "can't fork: $!, maybe you need to install cuetools";
    if( -f $cue->{FILE} ) {
        open(SHN,"|-","shnsplit","-o","wav","-O","never",$cue->{FILE}) or die "can't fork: $!";
#    } else {
#        warn "Trying to guess file to split";
#        my @wav=<*.wav>;
#        my @ape=<*.ape>;
#        if( @wav == 1 ) {
#            warn "Guessed ".$wav[0]."\n";
#            $FILE = $wav[0];
#        } elsif( @ape == 1) {
#            warn "Guessed ".$ape[0]."\n";
#            $FILE = $ape[0];
#        } else {
#            return;
#        }
#        open(SHN,"|-","shnsplit -o wav $cue->{FILE}") or die "can't fork: $!";
    }
    while(my $line = <CUEBRK>) {
        print SHN $line or die "can't write to pipe";
    }
    close(CUEBRK) or die "broken pipe: $! $?";
    close(SHN) or die "broken pipe: $! $?";
    foreach my $track (sort keys %{$cue->{TRACK}}) {
        my $wavfile = $SHNSPLIT_PREFIX."".$track.".wav";
        if( -f $wavfile) {
            my $mp3file = undef;
            if( defined $cue->{TRACK}{$track}{TITLE}
                && $cue->{TRACK}{$track}{TITLE} !~ m/unknown/ ) {

                $mp3file = $track.". ".$cue->{TRACK}{$track}{TITLE}.".mp3";

                $cue->{TRACK}{$track}{TITLE} =~ s#/##g;
                wav_to_mp3($SHNSPLIT_PREFIX."".$track.".wav", $mp3file);

                my $title = $cue->{TRACK}{$track}{TITLE};

                my @exec = ("eyeD3", "-2", "-t", $title, "-n", $track,  "--", $mp3file);
                print join(' ', @exec)."\n";
                system(@exec) == 0 or die "eyeD3 returned !=0";

            } else {
                $mp3file = $track.".mp3";
                wav_to_mp3($SHNSPLIT_PREFIX."".$track.".wav", $mp3file);
            }

            my $performer;
            if ($cue->{PERFORMER}) {
                $performer = $cue->{PERFORMER};
            } elsif ($cue->{TRACK}{$track}{PERFORMER}) {
                $performer = $cue->{TRACK}{$track}{PERFORMER};
            }

            if ($performer) {
                system("eyeD3", "-2", "-a", $performer, "-n", $track, "--", $mp3file) == 0 or die "eyeD3 returned !=0";
            }



        } else {
            die "can't find $wavfile";
        }
    }
    unlink($cuefile) if ( $opt{delcue} );
    return 1;
}

sub file_extension
{
    my $file = shift or return;
    my $ext = shift or return;
    if( $file =~ m/^(.*)\.\Q$ext\E$/i ) {
        return $1;
    } else {
        return;
    }
}

sub handle_cue_files
{
    my $file = $_;
}

sub print_errors
{
    if ($? == -1) {
        print "failed to execute: $!\n";
    }
    elsif ($? & 127) {
        printf "child died with signal %d, %s coredump\n",
            ($? & 127),  ($? & 128) ? 'with' : 'without';
    }

}

sub wav_to_mp3
{
    my $wav = shift or die "wav_to_mp3() without arg";
    my $dst = shift;
    if(my($name)=$wav =~ m/^(.*)\.wav$/i)  {
        my @cmd;
        if(defined $dst) {
            @cmd = ($LAME_PATH,@LAME_OPTS,$wav,$dst);
        } else {
            @cmd = ($LAME_PATH,@LAME_OPTS,$wav,$name.".mp3");
        }
        system(@cmd) == 0 or die "system(".join(",",@cmd)."): $!";
        if($opt{delwav}) {
            unlink($wav) or die "unlink($wav): $!";
        }
    } else {
        die "regexp failure ".$wav;
    }
}

sub found
{
    my $file = $_;
    if( defined $skip{$File::Find::name} ) {
        warn $File::Find::name." already done, skipping";
        return;
    }
    return if ! -f $file;
    my $prefix = undef;
    if ($prefix = file_extension($file,"mpc")) {
        #print "\n\nProcessing: ".$File::Find::name."\n\n";
        print colored("\n\nProcessing: ".$File::Find::name."\n\n","green");
        delete_wav_mp3($prefix);
        if( ! -f $prefix.".wav" && ! -f $prefix.".mp3" ) {
            my @cmd = ($MPPDEC,"--wav",$file,$prefix.".wav");
            system(@cmd) == 0 or system_failed(\@cmd);
            wav_to_mp3($prefix.".wav");
            unlink($file) if ( $opt{delmpc} && -f $prefix.".mp3" && -s $prefix.".mp3");
        } else {
            warn $prefix.".wav or ".$prefix.".mp3 exist\n";
            return;
        }
    } elsif ($prefix = file_extension($file,"ape")) {
        print colored("\n\nProcessing: ".$File::Find::name."\n\n","green");
        delete_wav_mp3($prefix);
        if( ! -f $prefix.".wav" && ! -f $prefix.".mp3" ) {
            my @cmd = ($MAC_PATH,$file,$prefix.".wav","-d");
            system(@cmd) == 0 or system_failed(\@cmd);
            wav_to_mp3($prefix.".wav");
            unlink($file) if ( $opt{delape} && -f $prefix.".mp3" && -s $prefix.".mp3");
        } else {
            warn $prefix.".wav or ".$prefix.".mp3 exist\n";
            return;
        }
    } elsif ($prefix = file_extension($file,"wma")) {
        print colored("\n\nProcessing: ".$File::Find::name."\n\n","green");
        my @cmd = ("mplayer", "-vo", "null", "-vc", "dummy", "-af", "resample=44100", "-ao", "pcm:waveheader",$file);
        system(@cmd) == 0 or system_failed(\@cmd);
        wav_to_mp3("audiodump.wav", $prefix.".mp3");
        print $file."\n";
        unlink($file) if ( $opt{delall} );

    } elsif ($prefix = file_extension($file, "m4a")) {
        print colored("\n\nProcessing: ".$File::Find::name."\n\n","green");
        my @cmd = ("ffmpeg", "-loglevel", "verbose",  "-y",  "-i", $file, "-acodec",  "libmp3lame",  "-q:a", "2", $prefix.".mp3");
        system(@cmd) == 0 or system_failed(\@cmd);
        unlink($file) if ( $opt{delall} );

    } elsif (file_extension($file,"cue")) {
        my $handled;
        if(my $cue = cue_parse($file)) {
            if ( file_extension($cue->{FILE},"wav") && -f $cue->{FILE} ) {
                print colored("\n\nProcessing: ".$File::Find::name."\n\n","green");
                if( cue_process($cue,$file) ) {
                    unlink($cue->{FILE}) if ( $opt{delwav} );
                    $handled=1;
                }
            }
            if ( file_extension($cue->{FILE},"wav") && ! -f $cue->{FILE} ) {
                my $tryape = $cue->{FILE};
                $tryape =~ s/\.wav$/\.ape/;
                if( -f $tryape ) {
                    $cue->{FILE} = $tryape;
                }
            }
            if ( file_extension($cue->{FILE},"ape") && -f $cue->{FILE} ) {
                print colored("\n\nProcessing: ".$File::Find::name."\n\n","green");
                if( cue_process($cue,$file) ) {
                    $skip{sane_path($File::Find::dir."/".$cue->{FILE})} = 1;
                    unlink($cue->{FILE}) if ( $opt{delape} );
                    $handled=1;
                }
            }
            if ( file_extension($cue->{FILE},"flac") && -f $cue->{FILE} ) {
                print colored("\n\nProcessing: ".$File::Find::name."\n\n","green");
                if( cue_process($cue,$file) ) {
                    $skip{sane_path($File::Find::dir."/".$cue->{FILE})} = 1;
                    unlink($cue->{FILE}) if ( $opt{delall} );
                    $handled=1;
                }
            }

            if (! $handled) {
                warn "FILE in cue ".color("red").$File::Find::name.color("reset")." is not .wav, .ape. Cwd: ".getcwd();
            }
        } else {
            die "Cue doesn't parse: ".color("red").$File::Find::name.color("red");
        }

    } elsif ($prefix = file_extension($file,"flac")) {
        my @cmd = ("flac", "-d", $file);
        system(@cmd) == 0 or die "@cmd returned !=0";
        wav_to_mp3($prefix.".wav", $prefix.".mp3");
    }
}

sub sane_path {
    my $dir = shift;
    $dir =~ s#/{2,}#/#go; # unless ($dir =~ m#://#);
    return $dir;
}
sub usage
{
    die<<EOT
$0 [dir0] [dir1] ...
    --delape
    --delmpc
    --delcue
    --delwav
    --delall

    converts ape and mpc files to mp3, deleting originals. If there's a cue file it splits the audio track in individual tracks by using the cue spec. If info is found id3 is set according to the cue sheet.
EOT


}


GetOptions(
    'delmpc' => \$opt{delmpc},
    'delape' => \$opt{delape},
    'delcue' => \$opt{delcue},
    'delwav' => \$opt{delwav},
    'delall' => \$opt{delall},
    'h' => \$opt{help},
) or usage;
usage if ($opt{help} || !@ARGV);
if( $opt{delall} ) {
    $opt{delmpc} = 1;
    $opt{delape} = 1;
    $opt{delcue} = 1;
    $opt{delwav} = 1;
}
foreach my $dir (@ARGV) {
    usage if ( ! -d $dir );
}
setpriority(0,0,19);
find(\&found,@ARGV);
