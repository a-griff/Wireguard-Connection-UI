#!/usr/bin/perl
use strict;
use warnings;
use Gtk3 -init;
use Glib qw/TRUE FALSE/;

our @profiles;

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

    # Correct way to validate sudo password
    open(my $sudo, "|-", "sudo", "-S", "-v") or return 0;
    print $sudo "$password\n";
    close($sudo);

    return $? == 0;
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
    if (opendir(my $dh, "/etc/wireguard")) {
        while (my $file = readdir($dh)) {
            next unless $file =~ /\.conf$/;
            $file =~ s/\.conf$//;
            push @list, $file;
        }
        closedir($dh);
        return @list if @list;
    }

    # Fallback: sudo ls (works even if /etc/wireguard isn't readable by user)
    open(my $fh, "-|", "sudo", "-n", "/bin/ls", "-1", "/etc/wireguard") or return ();

    while (<$fh>) {
        chomp;
        next unless /\.conf$/;
        s/\.conf$//;
        push @list, $_;
    }

    close $fh;
    return @list;
}

# ============================================================
# GET ACTIVE INTERFACES
# ============================================================

sub get_active_interfaces {

    my %active;

    open(my $fh, "-|", "sudo", "-n", "/usr/bin/wg", "show")
        or return ();

    while (<$fh>) {
        if (/^interface:\s+(\S+)/) {
            $active{$1} = 1;
        }
    }

    close $fh;
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
        system("sudo", "-n", "/usr/bin/wg-quick", "down", $iface);
    }
}

# ============================================================
# HELP WINDOW
# ============================================================

sub show_help {

    my $help_file = "$ENV{HOME}/bin/wg-ui-help.txt";
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

    my %widgets;

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

            system("sudo", "-n", "/usr/bin/wg-quick", "up", $profile);

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

            system("sudo", "-n", "/usr/bin/wg-quick", "down", $profile);

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

    $window->show_all;
    refresh_status();
    Glib::Timeout->add(3000, \&refresh_status);
}

# ============================================================
# MAIN
# ============================================================

exit 1 unless authenticate_sudo();

@profiles = get_profiles();
if (!@profiles) {
    show_error_and_exit("No WireGuard .conf files found (or not readable).\n\nExpected in:\n  /etc/wireguard\n\nIf /etc/wireguard is not readable by your user,\nallow sudo for:\n  /bin/ls /etc/wireguard\n(or adjust directory permissions/group).");
}

build_gui();
Gtk3->main;
