#!/usr/bin/perl
use strict;
use warnings;

# wg-ui.pl version 2.2
#
# Description:
#   GTK3 WireGuard profile controller for desktop Linux systems. It lists
#   WireGuard configs, shows active interfaces, and runs wg-quick through sudo.
#   On systems without a resolvconf executable, it uses a temporary copy of the
#   WireGuard config with Interface DNS lines removed; it does not modify
#   /etc/resolvconf.
#
# REQUIRES:
#   Perl modules: Gtk3, Glib, File::Temp
#   Commands: sudo, /usr/bin/env, ls, cat, wg, wg-quick
#   Files/directories: /etc/wireguard/*.conf
#
# SUDOERS:
#   <YOUR_USER> ALL=(root) /usr/bin/env PATH=* /usr/bin/ls /etc/wireguard, /usr/bin/env PATH=* /usr/bin/cat /etc/wireguard/*.conf, /usr/bin/env PATH=* /usr/bin/wg show, /usr/bin/env PATH=* /usr/bin/wg-quick up *, /usr/bin/env PATH=* /usr/bin/wg-quick down *

# User-adjustable settings
our $VERSION = '2.2';
our $WIREGUARD_CONFIG_DIR = '/etc/wireguard';
our $ENV_COMMAND = '/usr/bin/env';
our $ADMIN_PATH_PREFIX = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
our $HELP_FILE = "$ENV{HOME}/bin/wg-ui-help.txt";
our $SUDOERS_LINE = '<YOUR_USER> ALL=(root) /usr/bin/env PATH=* /usr/bin/ls /etc/wireguard, /usr/bin/env PATH=* /usr/bin/cat /etc/wireguard/*.conf, /usr/bin/env PATH=* /usr/bin/wg show, /usr/bin/env PATH=* /usr/bin/wg-quick up *, /usr/bin/env PATH=* /usr/bin/wg-quick down *';

our @profiles;
our %widgets;
our %cmd;
our $sudo_password;
our $sudo_askpass;

BEGIN {
    my @modules = (
        [ 'Gtk3',      [] ],
        [ 'Glib',      [qw(TRUE FALSE)] ],
        [ 'File::Temp', [qw(tempfile tempdir)] ],
    );

    foreach my $spec (@modules) {
        my ($module, $imports) = @$spec;
        eval "require $module; 1" or do {
            my $err = $@ || 'unknown error';
            print STDERR "Required Perl module not available: $module\n$err\n";
            exit 1;
        };
        $module->import(@$imports);
    }
}

# ============================================================
# ERROR WINDOW
# ============================================================

sub show_error_and_exit {
    my ($msg) = @_;

    my $dialog = Gtk3::MessageDialog->new(
        undef,
        ['modal'],
        'error',
        'close',
        $msg
    );
    $dialog->run;
    $dialog->destroy;

    exit 1;
}

sub startup_fatal {
    my ($msg) = @_;
    print STDERR "$msg\n";
    exit 1;
}

END {
    unlink $sudo_askpass if defined $sudo_askpass && -e $sudo_askpass;
}

sub init_sudo_askpass {
    my ($password) = @_;

    $sudo_password = $password;

    my ($fh, $path) = tempfile('wg-ui-askpass-XXXX', SUFFIX => '.sh', DIR => '/tmp', UNLINK => 0);
    print $fh "#!/bin/sh\n";
    print $fh "printf '%s\\n' \"\$WG_UI_SUDO_PASSWORD\"\n";
    close($fh) or return 0;
    chmod 0700, $path;

    $sudo_askpass = $path;
    return 1;
}

sub admin_path {
    return "$ADMIN_PATH_PREFIX:" . ($ENV{PATH} || '');
}

sub run_with_sudo_env(&) {
    my ($code) = @_;

    local $ENV{SUDO_ASKPASS} = $sudo_askpass;
    local $ENV{WG_UI_SUDO_PASSWORD} = $sudo_password;
    local $ENV{PATH} = admin_path();

    return $code->();
}

sub sudo_system {
    my (@args) = @_;
    my $path = admin_path();

    return run_with_sudo_env {
        system(
            $cmd{'sudo'},
            '-A',
            '-p', '',
            $ENV_COMMAND,
            "PATH=$path",
            @args
        );
    };
}

sub sudo_capture {
    my (@args) = @_;
    my @lines;
    my $path = admin_path();

    my $ok = run_with_sudo_env {
        open(
            my $fh,
            "-|",
            $cmd{'sudo'},
            '-A',
            '-p', '',
            $ENV_COMMAND,
            "PATH=$path",
            @args
        ) or return 0;

        @lines = <$fh>;
        close($fh);
        return 1;
    };

    return () unless $ok;
    return @lines;
}

sub warn_wgquick_environment {
    my @lines = sudo_capture($ENV_COMMAND);

    warn "wg-quick inherited environment from sudo $ENV_COMMAND:\n";
    warn @lines ? @lines : "  unable to capture environment\n";
}

sub diagnose_sudo_environment {
    print "wg-ui sudo diagnostics\n";
    print "user PATH=$ENV{PATH}\n\n";

    print "== sudo -V ==\n";
    system($cmd{'sudo'}, '-V');

    print "\n== sudo env ==\n";
    system($cmd{'sudo'}, 'env');

    print "\n== sudo sh -c 'echo \$PATH' ==\n";
    system($cmd{'sudo'}, 'sh', '-c', 'echo $PATH');

    print "\n== sudo sh -c 'which sysctl' ==\n";
    system($cmd{'sudo'}, 'sh', '-c', 'which sysctl');

    print "\n== sudo sh -c 'command -v sysctl' ==\n";
    system($cmd{'sudo'}, 'sh', '-c', 'command -v sysctl');

    print "\n== sudo sh -c 'ls -l /sbin/sysctl' ==\n";
    system($cmd{'sudo'}, 'sh', '-c', 'ls -l /sbin/sysctl');
}

# ============================================================
# COMMAND DETECTION
# ============================================================

sub find_command {
    my ($cmd) = @_;

    my @dirs = split(/:/, $ENV{PATH} || '');
    push @dirs, qw(
        /bin
        /usr/bin
        /sbin
        /usr/sbin
        /usr/local/bin
        /usr/local/sbin
    );

    my %seen;

    foreach my $dir (@dirs) {
        next if !$dir;
        next if $seen{$dir}++;

        my $path = "$dir/$cmd";
        return $path if -x $path;
    }

    return undef;
}

sub detect_commands {
    my @missing;

    foreach my $cmd (qw(sudo env ls cat wg wg-quick)) {
        my $path = find_command($cmd);

        if (!$path) {
            push @missing, $cmd;
            next;
        }

        $cmd{$cmd} = $path;
    }

    if (@missing) {
        show_error_and_exit(
            "Required command(s) not found:\n\n" .
            join("\n", map { "  $_" } @missing) . "\n\n" .
            "Checked PATH plus:\n" .
            "  /bin\n" .
            "  /usr/bin\n" .
            "  /sbin\n" .
            "  /usr/sbin\n" .
            "  /usr/local/bin\n" .
            "  /usr/local/sbin\n"
        );
    }

    if (!-x $ENV_COMMAND) {
        show_error_and_exit(
            "Required command not found or not executable:\n\n" .
            "  $ENV_COMMAND\n\n" .
            "This script uses $ENV_COMMAND after sudo so wg-quick receives\n" .
            "a complete administrative PATH."
        );
    }
}

sub profile_config_path {
    my ($profile) = @_;
    return "$WIREGUARD_CONFIG_DIR/$profile.conf";
}

sub read_profile_config_text {
    my ($profile) = @_;
    my $path = profile_config_path($profile);

    if (open(my $fh, '<', $path)) {
        local $/;
        my $text = <$fh>;
        close($fh);
        return $text;
    }

    my @lines = sudo_capture($cmd{'cat'}, $path);
    show_error_and_exit("Unable to read WireGuard config:\n\n  $path\n\nThis script needs read access so it can make a temporary copy when resolvconf is unavailable.") unless @lines;

    return join('', @lines);
}

sub prepare_wgquick_config {
    my ($profile) = @_;
    my $path = profile_config_path($profile);
    my $text = read_profile_config_text($profile);

    return ($path, undef) unless defined $text;
    return ($path, undef) if find_command('resolvconf');

    my $tmpdir = tempdir('wg-ui-XXXXXX', DIR => '/tmp', CLEANUP => 0);
    my $tmpfile = "$tmpdir/$profile.conf";

    open(my $fh, '>', $tmpfile) or show_error_and_exit("Unable to create temporary WireGuard config:\n\n  $tmpfile");
    chmod 0600, $tmpfile;

    my $created_at = scalar localtime();
    print $fh "# Temporary WireGuard config written by wg-ui.pl\n";
    print $fh "# Written because resolvconf is unavailable on this system.\n";
    print $fh "# Written at: $created_at\n";
    print $fh "# Probably safe to delete after wg-quick exits.\n";
    print $fh "\n";

    my $in_interface = 0;
    foreach my $line (split(/\n/, $text, -1)) {
        my $stripped = $line;
        $stripped =~ s/\#.*$//;
        $stripped =~ s/^\s+//;
        $stripped =~ s/\s+$//;

        if ($stripped =~ /^\[(.+)\]$/) {
            $in_interface = (lc($1) eq 'interface') ? 1 : 0;
        }

        next if $in_interface && $stripped =~ /^DNS\s*=/i;
        print $fh $line, "\n";
    }

    close($fh) or show_error_and_exit("Unable to finalize temporary WireGuard config:\n\n  $tmpfile");

    return ($tmpfile, sub {
        unlink $tmpfile;
        rmdir $tmpdir;
    });
}

# ============================================================
# AUTHENTICATION
# ============================================================

sub authenticate_sudo {

    my $dialog = Gtk3::Dialog->new(
        'Sudo Authentication',
        undef,
        ['modal'],
        'gtk-cancel' => 'cancel',
        'gtk-ok'     => 'ok',
    );

    my $content = $dialog->get_content_area;

    my $label = Gtk3::Label->new("Enter sudo password:");
    my $entry = Gtk3::Entry->new;
    $entry->set_visibility(FALSE);
    $entry->set_activates_default(TRUE);

    $content->pack_start($label, FALSE, FALSE, 6);
    $content->pack_start($entry, FALSE, FALSE, 6);

    $dialog->set_default_response('ok');
    $dialog->show_all;

    my $response = $dialog->run;
    my $password = $entry->get_text;

    $dialog->destroy;

    return 0 if $response ne 'ok';

    return 0 unless init_sudo_askpass($password);

    return run_with_sudo_env {
        system($cmd{'sudo'}, '-A', '-p', '', '-v') == 0;
    };
}

# ============================================================
# CSS STYLING
# ============================================================

sub apply_css {

    my $provider = Gtk3::CssProvider->new;

    my $css = qq{
        window { background: #1e1e1e; }

        label { font-size: 13px; }

        button {
            border-radius: 10px;
            padding: 6px 12px;
            border: 1px solid #444;
        }

        button:hover { background: #2a2a2a; }

        .btn-connect   { background: #2e7d32; color: white; }
        .btn-disconnect{ background: #c62828; color: white; }
        .btn-help      { background: #3b3b3b; color: white; }

        .btn-disabled  { background: #555; color: #aaa; }
    };

    $provider->load_from_data($css);

    Gtk3::StyleContext::add_provider_for_screen(
        Gtk3::Gdk::Screen::get_default(),
        $provider,
        Gtk3::STYLE_PROVIDER_PRIORITY_APPLICATION
    );
}

# ============================================================
# GET PROFILES
# ============================================================

sub get_profiles {

    my @list;

    # Try direct directory read (works only if user can read /etc/wireguard)
    if (opendir(my $dh, $WIREGUARD_CONFIG_DIR)) {
        while (my $file = readdir($dh)) {
            next unless $file =~ /\.conf$/;
            $file =~ s/\.conf$//;
            push @list, $file;
        }
        closedir($dh);
        return @list if @list;
    }

    # Fallback: sudo ls (works even if /etc/wireguard isn't readable by user)
    my @output = sudo_capture($cmd{'ls'}, $WIREGUARD_CONFIG_DIR);

    return () unless @output;

    foreach (@output) {
        chomp;
        next unless /\.conf$/;
        s/\.conf$//;
        push @list, $_;
    }

    return @list;
}

# ============================================================
# GET ACTIVE INTERFACES
# ============================================================

sub get_active_interfaces {

    my %active;

    my @output = sudo_capture($cmd{'wg'}, "show");
    return () unless @output;

    foreach (@output) {
        if (/^interface:\s+(\S+)/) {
            $active{$1} = 1;
        }
    }
    return %active;
}

sub is_profile_active {
    my ($profile) = @_;
    my %active = get_active_interfaces();
    return exists $active{$profile};
}

# ============================================================
# DISCONNECT ALL
# ============================================================

sub disconnect_all {
    my %active = get_active_interfaces();
    foreach my $iface (keys %active) {
        my ($config_file, $cleanup) = prepare_wgquick_config($iface);
        warn_wgquick_environment();
        sudo_system($cmd{'wg-quick'}, "down", $config_file);
        $cleanup->() if $cleanup;
    }
}

# ============================================================
# HELP WINDOW
# ============================================================

sub show_help {

    my $help_file = $HELP_FILE;
    my $text = "Help file not found:\n\n$help_file\n";

    if (-e $help_file) {
        if (open(my $fh, '<', $help_file)) {
            local $/;
            $text = <$fh>;
            close $fh;
        }
    }

    my $dialog = Gtk3::Dialog->new(
        'WireGuard UI Help',
        undef,
        ['modal'],
        'gtk-close' => 'close',
    );

    $dialog->set_default_size(650, 520);

    my $content = $dialog->get_content_area;

    my $scrolled = Gtk3::ScrolledWindow->new;
    $scrolled->set_policy('automatic', 'automatic');

    my $view = Gtk3::TextView->new;
    $view->set_editable(FALSE);
    $view->set_cursor_visible(FALSE);
    $view->get_buffer->set_text($text);

    $scrolled->add($view);
    $content->pack_start($scrolled, TRUE, TRUE, 0);

    $dialog->show_all;
    $dialog->run;
    $dialog->destroy;
}

# ============================================================
# STATUS REFRESH
# ============================================================

sub refresh_status {

    my %active = get_active_interfaces();

    foreach my $profile (@profiles) {

        my $is_active = exists $active{$profile};

        my $label = $widgets{$profile}->{label};
        my $connect = $widgets{$profile}->{connect};
        my $disconnect = $widgets{$profile}->{disconnect};

        # Clear any prior disabled styling
        $connect->get_style_context->remove_class('btn-disabled');
        $disconnect->get_style_context->remove_class('btn-disabled');

        if ($is_active) {

            $label->set_markup("<span foreground='#66ff66'><b>$profile</b></span>");

            $connect->set_sensitive(FALSE);
            $disconnect->set_sensitive(TRUE);

            $connect->get_style_context->add_class('btn-disabled');

        } else {

            $label->set_markup("<span foreground='#ff5555'><b>$profile</b></span>");

            $connect->set_sensitive(TRUE);
            $disconnect->set_sensitive(FALSE);

            $disconnect->get_style_context->add_class('btn-disabled');
        }
    }

    return TRUE;
}

# ============================================================
# GUI
# ============================================================

sub build_gui {

    apply_css();

    my $window = Gtk3::Window->new('toplevel');
    $window->set_title('WireGuard Control');
    $window->set_border_width(14);
    $window->set_default_size(460, 280);
    $window->signal_connect( destroy => sub { Gtk3->main_quit; });

    my $vbox = Gtk3::Box->new('vertical', 10);
    $window->add($vbox);

    %widgets = ();

    foreach my $profile (@profiles) {

        my $row = Gtk3::Box->new('horizontal', 10);

        my $label = Gtk3::Label->new($profile);
        $label->set_xalign(0);

        my $connect = Gtk3::Button->new('Connect');
        my $disconnect = Gtk3::Button->new('Disconnect');

        $connect->get_style_context->add_class('btn-connect');
        $disconnect->get_style_context->add_class('btn-disconnect');

        $row->pack_start($label, TRUE, TRUE, 0);
        $row->pack_start($connect, FALSE, FALSE, 0);
        $row->pack_start($disconnect, FALSE, FALSE, 0);

        $vbox->pack_start($row, FALSE, FALSE, 0);

        $widgets{$profile} = {
            label      => $label,
            connect    => $connect,
            disconnect => $disconnect,
        };

        # CONNECT ACTION
        $connect->signal_connect(clicked => sub {

            my ($config_file, $cleanup) = prepare_wgquick_config($profile);

            warn_wgquick_environment();
            sudo_system($cmd{'wg-quick'}, "up", $config_file);
            $cleanup->() if $cleanup;

            my $attempts = 0;
            Glib::Timeout->add(500, sub {
                $attempts++;
                refresh_status();
                return FALSE if is_profile_active($profile);
                return FALSE if $attempts > 20;
                return TRUE;
            });
        });

        # DISCONNECT ACTION
        $disconnect->signal_connect(clicked => sub {

            my ($config_file, $cleanup) = prepare_wgquick_config($profile);

            warn_wgquick_environment();
            sudo_system($cmd{'wg-quick'}, "down", $config_file);
            $cleanup->() if $cleanup;

            my $attempts = 0;
            Glib::Timeout->add(500, sub {
                $attempts++;
                refresh_status();
                return FALSE unless is_profile_active($profile);
                return FALSE if $attempts > 20;
                return TRUE;
            });
        });
    }

    # Bottom row: HELP (left) + GLOBAL DISCONNECT (right)
    my $bottom_row = Gtk3::Box->new('horizontal', 10);

    my $help_button = Gtk3::Button->new('HELP');
    $help_button->get_style_context->add_class('btn-help');

    my $global_disconnect = Gtk3::Button->new('GLOBAL DISCONNECT');
    $global_disconnect->get_style_context->add_class('btn-disconnect');

    $bottom_row->pack_start($help_button, FALSE, FALSE, 0);
    $bottom_row->pack_end($global_disconnect, FALSE, FALSE, 0);

    $vbox->pack_end($bottom_row, FALSE, FALSE, 2);

    $help_button->signal_connect(clicked => sub { show_help(); });

    $global_disconnect->signal_connect(clicked => sub {

        disconnect_all();

        my $attempts = 0;
        Glib::Timeout->add(500, sub {
            $attempts++;
            refresh_status();
            my %active = get_active_interfaces();
            return FALSE unless keys %active;
            return FALSE if $attempts > 20;
            return TRUE;
        });
    });

    $window->show_all;
    refresh_status();
    Glib::Timeout->add(3000, \&refresh_status);
}

# ============================================================
# MAIN
# ============================================================

detect_commands();

if (@ARGV && $ARGV[0] eq '--sudo-diagnostics') {
    diagnose_sudo_environment();
    exit 0;
}

eval { Gtk3::init(); 1 } or startup_fatal("Unable to initialize GTK3: $@");

exit 1 unless authenticate_sudo();

@profiles = get_profiles();

if (!@profiles) {
    show_error_and_exit("No WireGuard .conf files found (or not readable).\n\nExpected in:\n  $WIREGUARD_CONFIG_DIR\n\nIf $WIREGUARD_CONFIG_DIR is not readable by your user,\nallow sudo for:\n  $cmd{'ls'} $WIREGUARD_CONFIG_DIR\n(or adjust directory permissions/group).");
}

build_gui();
Gtk3->main;
