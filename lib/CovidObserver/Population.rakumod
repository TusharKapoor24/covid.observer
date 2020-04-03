unit module CovidObserver::Population;

use Locale::Codes::Country;
use Locale::US;
use Text::CSV;

use CovidObserver::DB;

constant $world-population is export = 7_800_000_000;

constant %continents is export =
    # AN => 'Antarctica',
    AF => 'Africa', AS => 'Asia', EU => 'Europe',
    NA => 'North America', OC => 'Oceania', SA => 'South America';

sub parse-population() is export {
    my %population;
    my %countries;
    my %age;

    # Population per country
    # constant $population_source = 'https://data.un.org/_Docs/SYB/CSV/SYB62_1_201907_Population,%20Surface%20Area%20and%20Density.csv';
    my $csv = Text::CSV.new;
    my $io = open 'data/SYB62_1_201907_Population, Surface Area and Density.csv';
    while my $row = $csv.getline($io) {
        my ($n, $country, $year, $type, $value) = @$row;
        next unless $type eq 'Population mid-year estimates (millions)';        

        my $cc = country2cc($country, silent => True);
        next unless $cc;

        $country = 'Iran' if $country ~~ /Iran/;
        $country = 'Venezuela' if $country ~~ /Venezuela/;
        $country = 'Bolivia' if $country ~~ /Bolivia/;
        $country = 'Tanzania' if $country ~~ /Tanzania/;
        $country = 'Moldova' if $country ~~ /Moldova/;
        $country = 'South Korea' if $country ~~ /Korea/;
        $country = 'Sint Maarten' if $country ~~ /'Sint Maarten'/;

        %countries{$cc} = $country;
        %population{$cc} = +$value;
    }

    # US population
    # https://www2.census.gov/programs-surveys/popest/tables/2010-2019/state/totals/nst-est2019-01.xlsx from
    # https://www.census.gov/data/datasets/time-series/demo/popest/2010s-state-total.html
    my @us-population = csv(in => 'data/us-population.csv');
    for @us-population -> ($state, $population) {
        my $state-cc = 'US/' ~ state2code($state);
        %countries{$state-cc} = $state;
        %population{$state-cc} = +$population / 1_000_000;
    }

    # Continents
    # constant $continents = 'https://pkgstore.datahub.io/JohnSnowLabs/country-and-continent-codes-list/country-and-continent-codes-list-csv_csv/data/b7876b7f496677669644f3d1069d3121/country-and-continent-codes-list-csv_csv.csv'
    my @continent-info = csv(in => 'data/country-and-continent-codes-list-csv_csv.csv');
    my %continent = @continent-info[1..*].map: {$_[3] => $_[1]};

    # Missing countries
    my @more-population = csv(in => 'data/more-population.csv');
    for @more-population -> ($cc, $continent, $country, $population) {
        %countries{$cc} = $country;
        %population{$cc} = +$population / 1_000_000;
        %continent{$cc} = $continent;
    }

    # Life expectancy (by birth)
    # From http://apps.who.int/gho/data/view.main.SDG2016LEXv?lang=en
    my @life-expectancy = csv(in => 'data/life-expectancy.csv');
    for @life-expectancy[2..*] -> ($country, $year, $age) {
        my $cc = country2cc($country);
        %age{$cc} = $age;
    }

    # China population
    # From https://en.wikipedia.org/wiki/ISO_3166-2:CN
    my @china-population = csv(in => 'data/china-regions.csv');
    for @china-population -> ($code, $region, $population) {
        my $cc = "CN/$code";
        %countries{$cc} = $region;
        %population{$cc} = +$population / 1_000_000;
    }

    return
        population => %population,
        countries  => %countries,
        continent  => %continent,
        age        => %age;
}

sub country2cc($country is copy, :$silent = False) is export {
    $country.=trim();

    state %force =
        'United Arab Emirates' => 'AE',
        'North Macedonia' => 'MK',
        'Brunei' => 'BN',
        'Vietnam' => 'VN',
        'Congo (Kinshasa)' => 'CD',
        'Democratic Republic of the Congo' => 'CD',
        'Cote d\'Ivoire' => 'CI',
        'Eswatini' => 'SZ',
        'Saint Vincent and the Grenadines' => 'VC',
        'Kosovo' => 'XK',
        'Congo (Brazzaville)' => 'CG',
        'Gambia, The' => 'GM',
        'Bahamas, The' => 'BS',
        'Russian Federation' => 'RU',
        'Russia' => 'RU',
        'Cabo Verde' => 'CV',
        'Sierra Leone' => 'SL',
        'Syrian Arab Republic' => 'SY',
        'Curaçao' => 'CW',
        'Curacao' => 'CW',
        'Sint Maarten' => 'SX',
        'Saint Martin' => 'SX',
        'Reunion' => 'RE',
        'The Bahamas' => 'BS',
        'The Gambia' => 'GM',
        'Mainland China' => 'CN',
        'UK' => 'GB',
        'Laos' => 'LA',
        'Macau' => 'MO',
        'Ivory Coast' => 'CI',
        'Saint Barthelemy' => 'BL',
        'Saint Barthélemy' => 'BL',
        'Palestine' => 'PS',
        'Dem. Rep. of the Congo' => 'CD',
        'Republic of the Congo' => 'CG',
        'East Timor' => 'TL',
        'West Bank and Gaza' => 'IL';

    $country = 'Lao People\'s Democratic Republic' if $country eq 'Lao People\'s Dem. Rep.';
    $country = 'Iran' if $country eq 'Iran (Islamic Republic of)';
    $country = 'South Korea' if $country eq 'Republic of Korea';
    $country = 'Czech Republic' if $country eq 'Czechia';
    $country = 'Venezuela' if $country ~~ /Venezuela/;
    $country = 'Moldova' if $country eq 'Republic of Moldova';
    $country = 'Bolivia' if $country ~~ /Bolivia/;
    $country = 'Tanzania' if $country eq 'United Rep. of Tanzania';
    $country = 'Micronesia' if $country ~~ /Micronesia/;
    $country = 'North Macedonia' if $country ~~ /'North Macedonia'/;
    $country = 'United Kingdom' if $country ~~ /'United Kingdom of Great Britain'/;
    $country = 'Saint Martin' if $country ~~ / 'St. Martin' | 'St Martin' /;
    $country = 'Hong Kong' if $country eq 'Hong Kong SAR';
    $country = 'Palestine' if $country ~~ /Palestine|Palestinian/;
    $country = 'Macau' if $country eq 'Macao SAR';
    $country = 'French Guiana' if $country eq 'Fench Guiana'; # typo in the source data
    $country = 'Myanmar' if $country eq 'Burma';
    $country = 'Bonaire' if $country ~~ /Bonaire/;

    $country ~~ s/'Korea, South'/South Korea/;
    $country ~~ s:g/'*'//;
    $country ~~ s/Czechia/Czech Republic/;

    my $cc;
    given $country {
        when %force{$country}:exists {$cc = %force{$country}}
        when 'US'                    {$cc = 'US'}
        default                      {$cc = countryToCode($country)}
    }

    unless $cc {
        note "WARNING: Country code not found for $country" unless $silent;
    }

    return $cc;
}

sub cc2country($cc) is export {
    my $country;

    state %force =
        'AE' => 'United Arab Emirates',
        'MK' => 'North Macedonia',
        'BN' => 'Brunei',
        'VN' => 'Vietnam',
        'CD' => 'Congo (Kinshasa)',
        'CI' => 'Cote d\'Ivoire',
        'SZ' => 'Eswatini',
        'VC' => 'Saint Vincent and the Grenadines',
        'XK' => 'Kosovo',
        'CG' => 'Congo (Brazzaville)',
        'GM' => 'Gambia, The',
        'BS' => 'Bahamas, The',
        'RU' => 'Russian Federation',
        'VE' => 'Venezuela',
        'IR' => 'Iran',
        'BO' => 'Bolivia',
        'TZ' => 'Tanzania',
        'MD' => 'Moldova',
        'KR' => 'South Korea',
        'CV' => 'Cabo Verde',
        'SL' => 'Sierra Leone',
        'CW' => 'Curaçao',
        'SX' => 'Saint Martin',
        'LA' => 'Laos',
        'FM' => 'Micronesia',
        'BL' => 'Saint Barthélemy',
        'PS' => 'Palestine',
        'CD' => 'Democratic Republic of the Congo',
        'CG' => 'Republic of the Congo';

    given $cc {
        when %force{$cc}:exists {$country = %force{$cc}}
        default                 {$country = codeToCountry($cc)}
    }

    return $country;
}

sub chinese-region-to-code($code) is export {
    state %provinces;

    unless %provinces.keys {
        my $sth = dbh.prepare('select cc, country from countries where cc like "CN/%"');
        $sth.execute();

        for $sth.allrows(:array-of-hash) -> %row {
            my $code = %row<cc>;
            $code ~~ s/'CN/'//;
            %provinces{%row<country>} = $code;
        }

        # different names
        %provinces{'Guangxi'} = 'GX';
        %provinces{'Xinjiang'} = 'XJ';
        %provinces{'Inner Mongolia'} = 'NM';
        %provinces{'Ningxia'} = 'NX';
        %provinces{'Macau'} = 'MO';
        %provinces{'Tibet'} = 'XZ';
    }

    return %provinces{$code};
}

sub state2code($state) is export {
    return 'VI' if $state eq 'United States Virgin Islands';

    return state-to-code($state);
}