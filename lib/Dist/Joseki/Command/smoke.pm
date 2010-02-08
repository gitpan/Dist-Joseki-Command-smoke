package Dist::Joseki::Command::smoke;
use strict;
use warnings;
use Cwd 'abs_path';
use Config 'myconfig';
use Dist::Joseki;
use Dist::Joseki::Find;
use File::Basename;
use File::Spec;
use File::Find;
use Template;
use Test::TAP::HTMLMatrix;
use Test::TAP::Model::Visual;
use YAML qw/LoadFile DumpFile/;
our $VERSION = '0.01';
use base 'Dist::Joseki::Cmd::Multiplexable';
__PACKAGE__->mk_hash_accessors(qw(dist_errors));

sub options {
    my ($self, $app, $cmd_config) = @_;
    return (
        $self->SUPER::options($app, $cmd_config),
        [ 'cover|c',  'also run coverage tests', ],
        [ 'resume|r', 'skip tests if there is a smoke.html already', ],
        [   'summary|s=s',
            'location of summary file',
            {   default => $cmd_config->{summary} || sprintf('%s/smoke.html',
                    (Dist::Joseki::Find->new->projroot)[0]),
            },
        ],
    );
}

sub run_smoke_tests {
    my $self                = shift;
    my $smoke_html_filename = 'smoke.html';
    my $smoke_yaml_filename = 'smoke.yaml';
    if (-e 'BUILD.SKIP') {
        warn "Skipping build because of BUILD.SKIP\n";
        return;
    }
    if ($self->opt_has_value('resume') && -e $smoke_html_filename) {
        warn "Skipping tests because --resume is given and smoke.html exists\n";
        return;
    }
    my $dist = Dist::Joseki->get_dist_type;
    $dist->ACTION_default;

    # Run smoke tests. Assumes that 'make' has already been run.
    my $meta = LoadFile('META.yml') or die "can't load META.yml\n";
    my $distname = $meta->{name};
    local $ENV{HARNESS_VERBOSE} = 1;
    my $model = Test::TAP::Model::Visual->new_with_tests(glob("t/*.t"));
    open my $fh, '>', $smoke_html_filename
      or die "can't open $smoke_html_filename for writing: $!\n";
    my $v = Test::TAP::HTMLMatrix->new($model, $distname);
    $v->has_inline_css(1);
    print $fh "$v";
    close $fh or die "can't close $smoke_html_filename: $!\n";

    # force scalar context so localtime() outputs readable string
    my $start_time = localtime($model->{meat}{start_time});
    my $end_time   = localtime($model->{meat}{end_time});
    my %summary    = (
        distname   => $distname,
        start_time => $start_time,
        end_time   => $end_time,
    );
    for (
        qw(percentage seen todo skipped passed
        failed unexpectedly_succeeded ratio)
      ) {
        my $method = "total_$_";
        $summary{$_} = $model->$method;
    }
    DumpFile($smoke_yaml_filename, \%summary);

    # Don't distclean so the generated test files (t/embedded) remain: They
    # are referenced from smoke.html pages.
}

sub run_coverage_tests {
    my $self = shift;
    return unless $self->opt_has_value('cover');
    if (-e 'BUILD.SKIP') {
        warn "Skipping coverage tests because of BUILD.SKIP\n";
        return;
    }
    if (-e 'COVER.SKIP') {
        warn "Skipping coverage tests because of COVER.SKIP\n";
        return;
    }

    # Run coverage tests. Assumes that 'make' has already been run.
    $self->safe_system('cover -delete');
    $self->safe_system(
        'HARNESS_PERL_SWITCHES=-MDevel::Cover=-ignore,^inc/ make test');
    $self->safe_system('cover');
}

sub create_summary {
    my $self        = shift;
    my $summary_dir = abs_path(dirname($self->opt('summary')));
    my @smoke;
    find(
        sub {
            return unless -f && $_ eq 'smoke.yaml';
            return if -e 'BUILD.SKIP';
            my $summary = LoadFile($_);
            unless ($summary->{distname}) {
                warn "$File::Find::name defines no distname\n";
                return;
            }

            # assume the summary_dir path is above all of the @basedir paths
            (my $rel_dir = $File::Find::dir) =~ s!^$summary_dir/!!;
            $summary->{link} = "$rel_dir/smoke.html";
            my $tee = 'smoketee.txt';
            if (-e $tee) {
                $summary->{rawlink} = "$rel_dir/$tee";
                my $raw = do { local (@ARGV, $/) = $tee; <> };
                $summary->{rawalert}++
                  if $raw =~ /Use of uninitialized value/
                      || $raw =~ / at .* line \d+/
                      || $raw =~ /Failed test /
                      || $raw =~ /Looks like you failed/
                      || $raw =~
                      /Looks like you planned \d+ tests but ran \d+ extra/
                      || $raw =~ /No tests run!/;
            }
            my $coverage_html = "$File::Find::dir/cover_db/coverage.html";
            if (-e $coverage_html) {
                $summary->{coverage_link} = "$rel_dir/cover_db/coverage.html";
                open my $fh, '<', $coverage_html
                  or die "can't open $coverage_html: $!\n";
                my $html = do { local $/; <$fh> };
                close $fh or die "can't close $coverage_html: $!\n";

                # crude but effective
                ($summary->{coverage_total}) =
                  $html =~ m!">(\d+\.\d+)</td></tr>\D+$!s;
            }
            $summary->{coverage_total} = sprintf "%.2f",
              defined $summary->{coverage_total}
              ? $summary->{coverage_total}
              : 0;
            push @smoke => $summary;
        },
        Dist::Joseki::Find->new->projroot
    );
    @smoke =
      map  { $_->[0] }
      sort { $a->[1] cmp $b->[1] }
      map  { [ $_, $_->{distname} ] } @smoke;
    my $template = $self->get_template;
    my $tt       = Template->new;
    $tt->process(
        \$template,
        {   smoke  => \@smoke,
            errors => scalar($self->dist_errors),
            config => myconfig(),
        },
        $self->opt('summary')
    ) || die $tt->error;
}

sub run {
    my $self = shift;
    $self->SUPER::run(@_);
    $self->create_summary;
}

sub run_single {
    my $self = shift;
    $self->SUPER::run_single(@_);
    $self->assert_is_dist_base_dir;
    $self->run_smoke_tests;
    $self->run_coverage_tests;

    # create summary here as well as in run() so if we're iterating over all
    # dists we can watch the summary grow
    $self->create_summary;
}

sub handle_dist_error {
    my ($self, $dist, $error) = @_;

    # we maintain a hash of lists, so get a reference and manipulate it
    # directly
    my $dist_errors = $self->dist_errors;
    push @{ $dist_errors->{$dist} } => $error;
}
sub get_template {
    <<'EOTEMPLATE' }
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0//EN"
    "http://www.w3.org/TR/REC-html40/strict.dtd">
<html>
<head>
<title>Smoke Test Result Summary</title>

<script type="text/javascript" src="sorttable.js"></script>
<style type="text/css">
<!--

body {
    font-family: Verdana, Arial, Helvetica, Tahoma;
    font-size: small;
    background-color: #EFEFEF;
}

a { color: #000066; text-decoration: none; font-style: italic; }

table {
    border-collapse: collapse;
}

th, td {
    border: 1px solid #444444;
    font-weight: bold;
    font-size: 1em;
    color: black;
    text-align: center;
    vertical-align: middle;
    background-color: #efefef;
    padding: 5px;
}

td.allfail {
    background-color: #ff6450;
}

td.allpass {
    background-color: #00ff00;
}

td.partial {
    background-color: #fffb50;
}

p.disterrorhead {
    font-weight: bold;
}

li.disterror {
    color: red;
}

-->
</style>

</head>
<body>
<h1>Smoke Test Result Summary</h1>

<table class="sortable" id="summary">
    <tr>
        <th id="0">Distribution</th>
        <th id="1">raw</th>
        <th id="2">coverage</th>
        <th id="3">tests</th>
        <th id="4">ok</th>
        <th id="5">fail</th>
        <th id="6">todo</th>
        <th id="7">skip</th>
        <th id="8">unexp.<BR>success</th>
        <th id="9">total</th>
        <th id="10">time</th>
    </tr>

[% FOR dist = smoke;
    IF dist.ratio == 0;
        tdclass = "allfail";
    ELSIF dist.ratio == 1;
        tdclass = "allpass";
    ELSE;
        tdclass = "partial";
    END;
%]
    <tr>
        <td>
            <a href="[% dist.link %]">[% dist.distname %]</a>
        </td>



        [% IF dist.rawlink %]

            [%
                IF dist.rawalert;
                    rawtdclass = "allfail";
                    rawtext    = "warn";
                ELSE;
                    rawtdclass = "allpass";
                    rawtext    = "ok";
                END;
            %]

            <td class="[% rawtdclass %]">
                <a href="[% dist.rawlink %]">[% rawtext %]</a>
            </td>
        [% ELSE %]
            <td class="allfail">MISSING</td>
        [% END %]



        [%
            IF dist.coverage_total + 0 == 0;
                covertdclass = "allfail";
            ELSIF dist.coverage_total + 0 == 100;
                covertdclass = "allpass";
            ELSE;
                covertdclass = "partial";
            END;
        %]

        <td class="[% covertdclass %]">
            [% IF dist.coverage_link %]
                <a href="[% dist.coverage_link %]">
            [% END %]
                    [% dist.coverage_total %]%
            [% IF dist.coverage_link %]
                </a>
            [% END %]
        </td>

        <td class="[% tdclass %]">[% dist.seen %]</td>
        <td class="[% tdclass %]">[% dist.passed %]</td>
        <td class="[% tdclass %]">[% dist.failed %]</td>
        <td class="[% tdclass %]">[% dist.todo %]</td>
        <td class="[% tdclass %]">[% dist.skipped %]</td>
        <td class="[% tdclass %]">[% dist.unexpectedly_succeeded %]</td>
        <td class="[% tdclass %]">[% dist.percentage %]</td>
        <td class="[% tdclass %]">[% dist.end_time %]</td>
    </tr>
[% END %]
</table>

[% IF errors.size > 0 %]
    <h2>Errors</h2>

    <p>There were problems.</p>

    [% FOREACH dist IN errors.keys.sort %]
        <p class="disterrorhead">[% dist %]</p>

        <ul>
        [% FOREACH error IN errors.$dist %]
            <li class="disterror">[% error %]</li>
        [% END %]
        </ul>
    [% END %]
[% END %]

<h2>Config</h2>

<pre>
<code>
[% config %]
</code>
</pre>

</body>
</html>
EOTEMPLATE

sub hook_in_dist_loop_begin {
    my ($self, $dist) = @_;
    $self->SUPER::hook_in_dist_loop_begin($dist);
    $self->print_header($dist);
}
1;
__END__

=head1 NAME

Dist::Joseki::Command::smoke - run smoke tests for your distribution

=head1 SYNOPSIS

    # dist smoke

=head1 DESCRIPTION

This command plugin for L<Dist::Joseki> gives you a new command: C<dist
smoke> runs smoke tests for your distribution.

=head1 METHODS

=over 4

=back

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

Please report any bugs or feature requests through the web interface at
L<http://rt.cpan.org>.

=head1 INSTALLATION

See perlmodinstall for information and options on installing Perl modules.

=head1 AVAILABILITY

The latest version of this module is available from the Comprehensive Perl
Archive Network (CPAN). Visit L<http://www.perl.com/CPAN/> to find a CPAN site
near you. Or see L<http://search.cpan.org/dist/Dist-Joseki-Command-smoke/>.

The development version lives at
L<http://github.com/hanekomu/dist-joseki-command-smoke/>.  Instead of sending
patches, please fork this project using the standard git and github
infrastructure.

=head1 AUTHORS

Marcel GrE<uuml>nauer, C<< <marcel@cpan.org> >>

=head1 COPYRIGHT AND LICENSE

Copyright 2010 by Marcel GrE<uuml>nauer

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
