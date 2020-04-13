unit module CovidObserver::Data;

use HTTP::UserAgent;
use Text::CSV;
use IO::String;

use CovidObserver::Population;
use CovidObserver::Geo;

sub read-jhu-data(%stats) is export {
    my %dates;
    my %cc;

    my %raw;
    my %us-recovered;
    for dir('COVID-19/csse_covid_19_data/csse_covid_19_daily_reports', test => /'.csv'$/).sort(~*.path) -> $path {
        $path.path ~~ / (\d\d) '-' (\d\d) '-' \d\d(\d\d) '.csv' /;
        my $month = ~$/[0];
        my $day   = ~$/[1];
        my $year  = ~$/[2];
        my $date = "$month/$day/$year"; # TODO
        %dates{$date} = 1;

        my $data = $path.slurp;
        my $fh = IO::String.new($data);

        my $csv = Text::CSV.new;
        my @headers = $csv.getline($fh);

        while my @row = $csv.getline($fh) {
            my ($country, $confirmed, $failed, $recovered);
            my $region = '';

            if @headers[0] ne 'FIPS' {
                if $date ne '04/12/20' { # TODO switch to column names (if that helps)
                    $country = @row[1] || '';
                    $region  = @row[0] || '';

                    ($confirmed, $failed, $recovered) = @row[3..5];
                }
                else {
                    $country = @row[1] || '';
                    $region  = @row[0] || '';

                    ($confirmed, $failed, $recovered) = @row[5..7];
                }
            }
            else {
                $country = @row[3] || '';
                $region  = @row[2] || '';

                ($confirmed, $failed, $recovered) = @row[7..9];
            }

            if $country eq 'Netherlands' && $region {
                $country = $region;
            }
            elsif $country eq 'France' && $region {
                $country = $region if $date ne "03/23/20"; # Wrongly mixed with French Polynesia data for this date
            }
            elsif $country eq 'Channel Islands' {
                $country = 'United Kingdom';
                $region = '';
            }
            elsif $country eq 'United Kingdom' && $region {
                if $region eq 'Channel Islands' {
                    $region = '';
                }
                else {
                    $country = $region;
                }
            }
            elsif $country eq 'Taipei and environs' {
                $country = 'China';
                $region = 'Taiwan';
            }

            if $region eq 'Wuhan Evacuee' {
                # $country = 'US';
                $region = ''; # Currently located in the US regardles nationality?
            }

            my $cc = country2cc($country);
            next unless $cc;

            next if $cc eq 'RU'; # Processed from a separate data source

            my $region-cc = '';

            if $cc eq 'US' && $region eq 'Recovered' { # Canada is fine without this
                %us-recovered{$date} = $recovered // 0;
            }

            if $cc eq 'US' && 
               $region && $region !~~ /Princess/ && $region !~~ /','/
               && $region ne 'US' { # What is 'US/US'?

                $region-cc = state2code($region);
                unless $region-cc {
                    say "WARNING: State code not found for US/$region";
                    next;
                }
                $region-cc = 'US/' ~ $region-cc;
            }
            elsif $cc eq 'CN' {
                if $region {
                    $region-cc = 'CN/' ~ chinese-region-to-code($region);
                }
            }
            
            next if $cc eq 'US' && $region-cc eq '';

            %cc{$cc} = 1;
            %cc{$region-cc} = 1 if $region-cc;

            # += as US divides further per state AND further per city
            %raw{$cc}{$region-cc}{$date}<confirmed> += $confirmed // 0;
            %raw{$cc}{$region-cc}{$date}<failed>    += $failed // 0;
            %raw{$cc}{$region-cc}{$date}<recovered> += $recovered // 0;
        }
    }

    # Count per-day data
    for %raw.keys -> $cc { # only countries
        for %raw{$cc}.keys -> $region-cc { # regions or '' for countries without them
            for %raw{$cc}{$region-cc}.keys -> $date {
                my $confirmed = %raw{$cc}{$region-cc}{$date}<confirmed>;
                my $failed    = %raw{$cc}{$region-cc}{$date}<failed>;
                my $recovered = %raw{$cc}{$region-cc}{$date}<recovered>;

                if $region-cc {
                    %stats<confirmed><per-day>{$region-cc}{$date} = $confirmed;
                    %stats<failed><per-day>{$region-cc}{$date}    = $failed;
                    %stats<recovered><per-day>{$region-cc}{$date} = $recovered;
                }

                # += if there's a region, otherwise bare =
                %stats<confirmed><per-day>{$cc}{$date} += $confirmed;
                %stats<failed><per-day>{$cc}{$date}    += $failed;
                %stats<recovered><per-day>{$cc}{$date} += $recovered;
            }
        }
    }

    for %us-recovered.keys -> $date {
        %stats<recovered><per-day><US>{$date} = %us-recovered{$date};
    }

    return %dates.keys.sort[*-1];
}

sub read-ru-data(%stats) is export {
    my %dates;
    my %cc;

    my %raw;
    my %us-recovered;
    for dir('series/ru', test => /'.csv'$/).sort(~*.path) -> $path {
        $path.path ~~ / 'ru-' \d\d(\d\d) '-' (\d\d) '-' (\d\d) '.csv' /;
        my $year  = ~$/[0];
        my $month = ~$/[1];
        my $day   = ~$/[2];
        my $date = "$month/$day/$year"; # TODO
        %dates{$date} = 1;

        my $data = $path.slurp;
        my $fh = IO::String.new($data);

        my $csv = Text::CSV.new(sep => "\t");

        my $cc = 'RU'; # Should replaces JHU's data
        while my @row = $csv.getline($fh) {
            my ($region, $confirmed, $recovered, $failed) = @row;

            my $region-cc = ru-region-to-code($region);
            $region-cc = "RU/$region-cc";

            %cc{$cc} = 1;
            %cc{$region-cc} = 1;

            %raw{$cc}{$region-cc}{$date}<confirmed> = $confirmed // 0;
            %raw{$cc}{$region-cc}{$date}<failed>    = $failed // 0;
            %raw{$cc}{$region-cc}{$date}<recovered> = $recovered // 0;
        }
    }

    # %raw<RU2>:delete;

    # Count per-day data
    for %raw.keys -> $cc { # only countries
        for %raw{$cc}.keys -> $region-cc { # regions or '' for countries without them
            for %raw{$cc}{$region-cc}.keys -> $date {
                my $confirmed = %raw{$cc}{$region-cc}{$date}<confirmed>;
                my $failed    = %raw{$cc}{$region-cc}{$date}<failed>;
                my $recovered = %raw{$cc}{$region-cc}{$date}<recovered>;

                if $region-cc {
                    %stats<confirmed><per-day>{$region-cc}{$date} = $confirmed;
                    %stats<failed><per-day>{$region-cc}{$date}    = $failed;
                    %stats<recovered><per-day>{$region-cc}{$date} = $recovered;
                }

                # += if there's a region, otherwise bare =
                %stats<confirmed><per-day>{$cc}{$date} += $confirmed;
                %stats<failed><per-day>{$cc}{$date}    += $failed;
                %stats<recovered><per-day>{$cc}{$date} += $recovered;
            }
        }
    }

    return %dates.keys.sort[*-1];
}

sub data-count-totals(%stats, %stop-date) is export {
    my %dates;
    my %cc;

    # Find all dates and all countries from all existing datasets
    for %stats<confirmed><per-day>.keys -> $cc {
        %cc{$cc} = 1;

        my $stop-date = $cc ne 'RU' ?? %stop-date<World> !! %stop-date<RU>;
        for %stats<confirmed><per-day>{$cc}.keys.sort -> $date {
            %dates{$date} = 1;

            last if $date eq $stop-date;
        }
    }

    # Fill zeroes for missing dates/countries
    for %cc.keys -> $cc { # including regions
        my $stop-date = $cc ne 'RU' ?? %stop-date<World> !! %stop-date<RU>;

        for %dates.keys.sort -> $date {
            %stats<confirmed><per-day>{$cc}{$date} //= 0;
            %stats<failed><per-day>{$cc}{$date}    //= 0;
            %stats<recovered><per-day>{$cc}{$date} //= 0;

            last if $date eq $stop-date;
        }
    }

    # Count totals
    for %cc.keys -> $cc { # including regions
        my $date = $cc ne 'RU' ?? %stop-date<World> !! %stop-date<RU>;

        %stats<confirmed><total>{$cc} = %stats<confirmed><per-day>{$cc}{$date};
        %stats<failed><total>{$cc}    = %stats<failed><per-day>{$cc}{$date};
        %stats<recovered><total>{$cc} = %stats<recovered><per-day>{$cc}{$date};
    }

    # Count totals per day
    for %cc.keys -> $cc {
        # only countries
        next if $cc ~~ /'/'/;

        my $stop-date = $cc ne 'RU' ?? %stop-date<World> !! %stop-date<RU>;

        for %dates.keys.sort -> $date {
            %stats<confirmed><daily-total>{$date} += %stats<confirmed><per-day>{$cc}{$date};
            %stats<failed><daily-total>{$date}    += %stats<failed><per-day>{$cc}{$date};
            %stats<recovered><daily-total>{$date} += %stats<recovered><per-day>{$cc}{$date};

            last if $date eq $stop-date;
        }
    }
}
