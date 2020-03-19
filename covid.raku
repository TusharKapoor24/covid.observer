#!/usr/bin/env raku

use HTTP::UserAgent;
use Locale::Codes::Country;
use Locale::US;
use DBIish;
use Text::CSV;
use JSON::Tiny;

constant %covid-sources =
    confirmed => 'https://github.com/CSSEGISandData/COVID-19/raw/master/csse_covid_19_data/csse_covid_19_time_series/time_series_19-covid-Confirmed.csv',
    failed    => 'https://github.com/CSSEGISandData/COVID-19/raw/master/csse_covid_19_data/csse_covid_19_time_series/time_series_19-covid-Deaths.csv',
    recovered => 'https://github.com/CSSEGISandData/COVID-19/raw/master/csse_covid_19_data/csse_covid_19_time_series/time_series_19-covid-Recovered.csv';

constant $world-population = 7_800_000_000;

constant %continents =
    # AN => 'Antarctica',
    AF => 'Africa', AS => 'Asia', EU => 'Europe',
    NA => 'North America', OC => 'Oceania', SA => 'South America';

sub dbh() {
    state $dbh = DBIish.connect('mysql', :host<localhost>, :user<covid>, :password<covid>, :database<covid>);
    return $dbh;
}

multi sub MAIN('population') {
    my %population = parse-population();

    say "Updating database...";

    dbh.execute('delete from countries');
    for %population<countries>.kv -> $cc, $country {
        my $n = %population<population>{$cc};

        my $continent = $cc ~~ /'/'/ ?? '' !! %population<continent>{$cc};
        say "$cc, $continent, $country, $n";

        my $sth = dbh.prepare('insert into countries (cc, continent, country, population) values (?, ?, ?, ?)');
        $sth.execute($cc, $continent, $country, $n);
    }
}

multi sub MAIN('fetch') {
    my %stats = fetch-covid-data(%covid-sources);
    
    say "Updating database...";

    dbh.execute('delete from per_day');
    dbh.execute('delete from totals');
    dbh.execute('delete from daily_totals');

    my %confirmed = %stats<confirmed>;
    my %failed = %stats<failed>;
    my %recovered = %stats<recovered>;

    for %confirmed<per-day>.keys -> $cc {
        for %confirmed<per-day>{$cc}.kv -> $date, $confirmed {
            my $failed = %failed<per-day>{$cc}{$date};
            my $recovered = %recovered<per-day>{$cc}{$date};

            my $sth = dbh.prepare('insert into per_day (cc, date, confirmed, failed, recovered) values (?, ?, ?, ?, ?)');
            $sth.execute($cc, date2yyyymmdd($date), $confirmed, $failed, $recovered);
        }

        my $sth = dbh.prepare('insert into totals (cc, confirmed, failed, recovered) values (?, ?, ?, ?)');
        $sth.execute($cc, %confirmed<total>{$cc}, %failed<total>{$cc}, %recovered<total>{$cc});
    }

    for %confirmed<daily-total>.kv -> $date, $confirmed {
        my $failed = %failed<daily-total>{$date};
        my $recovered = %recovered<daily-total>{$date};

        my $sth = dbh.prepare('insert into daily_totals (date, confirmed, failed, recovered) values (?, ?, ?, ?)');
        $sth.execute(date2yyyymmdd($date), $confirmed, $failed, $recovered);
    }
}

sub date2yyyymmdd($date) {
    my ($month, $day, $year) = $date.split('/');
    $year += 2000;
    my $yyyymmdd = '%i%02i%02i'.sprintf($year, $month, $day);

    return $yyyymmdd;
}

multi sub MAIN('generate') {
    my %countries = get-countries();

    my %per-day = get-per-day-stats();
    my %totals = get-total-stats();
    my %daily-totals = get-daily-totals-stats();

    generate-world-stats(%countries, %per-day, %totals, %daily-totals);

    generate-countries-stats(%countries, %per-day, %totals, %daily-totals);
    generate-china-level-stats(%countries, %per-day, %totals, %daily-totals);

    for get-known-countries() -> $cc {
        generate-country-stats($cc, %countries, %per-day, %totals, %daily-totals);
    }

    for %continents.keys -> $cont {
        generate-continent-stats($cont, %countries, %per-day, %totals, %daily-totals);
    }

    generate-continent-graph(%countries, %per-day, %totals, %daily-totals);

    geo-sanity();
}

multi sub MAIN('sanity') {
    geo-sanity();
}

multi sub MAIN('404') {
    html-template('/404', '404 Virus Not Found', q:to/HTML/);
        <h1 style="margin-top: 2em; margin-bottom: 3em">Error 404<br/>Virus Not Found</h1>
    HTML
}

sub geo-sanity() {
    my $sth = dbh.prepare('select per_day.cc from per_day left join countries using (cc) where countries.cc is null group by 1');
    $sth.execute();

    for $sth.allrows() -> $cc {
        my $variant = '';
        $variant = codeToCountry(~$cc) if $cc.chars == 2;
        say "Missing country information $cc $variant";
    }
}

sub parse-population() {
    my %population;
    my %countries;

    # Population per country
    # constant $population_source = 'https://data.un.org/_Docs/SYB/CSV/SYB62_1_201907_Population,%20Surface%20Area%20and%20Density.csv';
    my $csv = Text::CSV.new;
    my $io = open 'SYB62_1_201907_Population, Surface Area and Density.csv';
    while my $row = $csv.getline($io) {
        my ($n, $country, $year, $type, $value) = @$row;
        next unless $type eq 'Population mid-year estimates (millions)';        

        $country = 'Iran' if $country eq 'Iran (Islamic Republic of)';
        $country = 'South Korea' if $country eq 'Republic of Korea';
        $country = 'Czech Republic' if $country eq 'Czechia';
        $country = 'Venezuela' if $country eq 'Venezuela (Boliv. Rep. of)';
        $country = 'Moldova' if $country eq 'Republic of Moldova';
        $country = 'Bolivia' if $country eq 'Bolivia (Plurin. State of)';
        $country = 'Tanzania' if $country eq 'United Rep. of Tanzania';

        my $cc = countryToCode($country);
        next unless $cc;

        %countries{$cc} = $country;
        %population{$cc} = +$value;
    }

    # US population
    # https://www2.census.gov/programs-surveys/popest/tables/2010-2019/state/totals/nst-est2019-01.xlsx from
    # https://www.census.gov/data/datasets/time-series/demo/popest/2010s-state-total.html
    my @us-population = csv(in => 'us-population.csv');
    for @us-population -> ($state, $population) {
        my $state-cc = 'US/' ~ state-to-code($state);
        %countries{$state-cc} = $state;
        %population{$state-cc} = +$population / 1_000_000;
    }

    # Continents
    # constant $continents = 'https://pkgstore.datahub.io/JohnSnowLabs/country-and-continent-codes-list/country-and-continent-codes-list-csv_csv/data/b7876b7f496677669644f3d1069d3121/country-and-continent-codes-list-csv_csv.csv'
    my @continent-info = csv(in => 'country-and-continent-codes-list-csv_csv.csv');
    my %continent = @continent-info[1..*].map: {$_[3] => $_[1]};

    return
        population => %population,
        countries  => %countries,
        continent  => %continent;
}

sub fetch-covid-data(%sources) {
    my $ua = HTTP::UserAgent.new;
    $ua.timeout = 30;

    my %stats;

    for %sources.kv -> $type, $url {
        say "Getting '$type'...";

        my $response = $ua.get($url);

        if $response.is-success {
            say "Processing '$type'...";
            %stats{$type} = extract-covid-data($response.content);
        }
        else {
            die $response.status-line;
        }
    }

    return %stats;
}

sub extract-covid-data($data) {
    my $csv = Text::CSV.new;
    my $fh = IO::String.new($data);

    my @headers = $csv.getline($fh);
    my @dates = @headers[4..*];

    my %per-day;
    my %total;
    my %daily-per-country;
    my %daily-total;

    while my @row = $csv.getline($fh) {
        my $country = @row[1] || '';
        $country ~~ s/'Korea, South'/South Korea/;
        $country ~~ s/Russia/Russian Federation/;
        $country ~~ s:g/'*'//;
        $country ~~ s/Czechia/Czech Republic/;
        $country ~~ s:g/\"//; #"

        my $cc = countryToCode($country) || '';
        $cc = 'US' if $country eq 'US';

        next unless $cc;

        for @dates Z @row[4..*] -> ($date, $n) {
            %per-day{$cc}{$date} += $n;
            %daily-per-country{$date}{$cc} += $n;

            my $uptodate = %per-day{$cc}{$date};
            %total{$cc} = $uptodate if !%total{$cc} or $uptodate > %total{$cc};
        }

        if $cc eq 'US' {
            my $state = @row[0];

            if $state && $state !~~ /Princess/ && $state !~~ /','/ {
                my $state-cc = 'US/' ~ state-to-code($state);

                for @dates Z @row[4..*] -> ($date, $n) {
                    %per-day{$state-cc}{$date} += $n;
                    %daily-per-country{$date}{$state-cc} += $n;

                    my $uptodate = %per-day{$state-cc}{$date};
                    %total{$state-cc} = $uptodate if !%total{$state-cc} or $uptodate > %total{$state-cc};
                }
            }
        }
    }

    for %daily-per-country.kv -> $date, %per-country {
        %daily-total{$date} = [+] %per-country.values;
    }

    return 
        per-day => %per-day,
        total => %total,
        daily-total => %daily-total;
}

sub get-countries() {
    my $sth = dbh.prepare('select cc, country, continent, population from countries');
    $sth.execute();

    my %countries;
    for $sth.allrows(:array-of-hash) -> %row {
        my $country = %row<country>;
        $country = "US/$country" if %row<cc> ~~ /US'/'/;
        my %data =
            country => $country,
            population => %row<population>,
            continent => %row<continent>;
        %countries{%row<cc>} = %data;
    }

    return %countries;
}

sub get-known-countries() {
    my $sth = dbh.prepare('select distinct countries.cc, countries.country from totals join countries on countries.cc = totals.cc order by countries.country');
    $sth.execute();

    my @countries;
    for $sth.allrows() -> @row {
        @countries.push(@row[0]);
    }

    return @countries;    
}

sub get-total-stats() {
    my $sth = dbh.prepare('select cc, confirmed, failed, recovered from totals');
    $sth.execute();

    my %stats;
    for $sth.allrows(:array-of-hash) -> %row {
        my %data =
            confirmed => %row<confirmed>,
            failed => %row<failed>,
            recovered => %row<recovered>;
        %stats{%row<cc>} = %data;
    }

    return %stats;
}

sub get-per-day-stats() {
    my $sth = dbh.prepare('select cc, date, confirmed, failed, recovered from per_day');
    $sth.execute();

    my %stats;
    for $sth.allrows(:array-of-hash) -> %row {
        my %data =
            confirmed => %row<confirmed>,
            failed => %row<failed>,
            recovered => %row<recovered>;
        %stats{%row<cc>}{%row<date>} = %data;
    }

    return %stats;
}

sub get-daily-totals-stats() {
    my $sth = dbh.prepare('select date, confirmed, failed, recovered from daily_totals');
    $sth.execute();

    my %stats;
    for $sth.allrows(:array-of-hash) -> %row {
        my %data =
            confirmed => %row<confirmed>,
            failed => %row<failed>,
            recovered => %row<recovered>;
        %stats{%row<date>} = %data;
    }

    return %stats;
}

sub generate-world-stats(%countries, %per-day, %totals, %daily-totals) {
    say 'Generating world data...';

    my $chart1data = chart-pie(%countries, %per-day, %totals, %daily-totals);
    my $chart2data = chart-daily(%countries, %per-day, %totals, %daily-totals);
    my $chart3 = number-percent(%countries, %per-day, %totals, %daily-totals);

    my $chart7data = daily-speed(%countries, %per-day, %totals, %daily-totals);

    my $country-list = country-list(%countries);
    my $continent-list = continent-list();

    my $content = qq:to/HTML/;
        <h1>COVID-19 World Statistics</h1>

        <div id="block2">
            <h2>Affected World Population</h2>
            <div id="percent">$chart3&thinsp;%</div>
            <p>This is the part of confirmed infection cases against the total 7.8 billion of the world population.</p>
        </div>

        <div id="block1">
            <h2>Recovery Pie</h2>
            <canvas id="Chart1"></canvas>
            <p>The whole pie reflects the total number of confirmed cases of people infected by coronavirus in the whole world.</p>
            <script>
                var ctx1 = document.getElementById('Chart1').getContext('2d');
                chart[1] = new Chart(ctx1, $chart1data);
            </script>
        </div>

        <div id="block3">
            <h2>Daily Flow</h2>
            <canvas id="Chart2"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale2" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale2" onclick="log_scale(this, 2)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale2"> Logarithmic scale</label>
            </p>
            <p>The height of a single bar is the total number of people suffered from Coronavirus confirmed to be infected in the world. It includes three parts: those who could or could not recover and those who are currently in the active phase of the disease.</p>
            <script>
                var ctx2 = document.getElementById('Chart2').getContext('2d');
                chart[2] = new Chart(ctx2, $chart2data);
            </script>
        </div>

        <div id="block7">
            <a name="speed"></a>
            <h2>Daily Speed</h2>
            <p>This graph shows the speed of growth (in %) over time. The main three parameters are the number of confirmed cases, the number of recoveries and failures. The orange line is the speed of changing of the number of active cases (i.e., of those, who are still ill).</p>
            <canvas id="Chart7"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale7" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale7" onclick="log_scale(this, 7)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale7"> Logarithmic scale</label>
            </p>
            <script>
                var ctx7 = document.getElementById('Chart7').getContext('2d');
                chart[7] = new Chart(ctx7, $chart7data);
            </script>
            <p>Note 1. In calculations, the 3-day moving average is used.</p>
            <p>Note 2. When the speed is positive, the number of cases grows every day. The line going down means that the speed decreeses, and while there may be more cases the next day, the disease spread is slowing down. If the speed goes below zero, that means that less cases registered today than yesterday.</p>
        </div>

        $continent-list
        $country-list

        HTML

    html-template('/', 'World statistics', $content);
}

sub generate-countries-stats(%countries, %per-day, %totals, %daily-totals) {
    say 'Generating countries data...';

    my %chart5data = countries-first-appeared(%countries, %per-day, %totals, %daily-totals);
    my $chart4data = countries-per-capita(%countries, %per-day, %totals, %daily-totals);
    my $countries-appeared = countries-appeared-this-day(%countries, %per-day, %totals, %daily-totals);

    my $country-list = country-list(%countries);
    my $continent-list = continent-list();

    my $percent = sprintf('%.1f', 100 * %chart5data<current-n> / %chart5data<total-countries>);

    my $content = qq:to/HTML/;
        <h1>Coronavirus in different countries</h1>

        <div id="block5">
            <h2>Number of Countires Affected</h2>
            <p>%chart5data<current-n> countires are affected, which is {$percent}&thinsp;\% from the total %chart5data<total-countries> countries.</p>
            <canvas id="Chart5"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale5" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale5" onclick="log_scale(this, 5)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale5"> Logarithmic scale</label>
            </p>
            <p>On this graph, you can see how many countries did have data about confirmed coronavirus invection for a given date over the last months.</p>
            <script>
                var ctx5 = document.getElementById('Chart5').getContext('2d');
                chart[5] = new Chart(ctx5, %chart5data<json>);
            </script>
        </div>

        <div id="block6">
            <h2>Countries Appeared This Day</h2>
            <p>This list gives you the overview of when the first confirmed case was reported in the given country. Or, you can see here, which countries entered the chart in the recent days. The number in parentheses is the number of confirmed cases in that country on that date.</p>
            $countries-appeared
        </div>

        <div id="block4">
            <h2>Top 30 Affected per Million</h2>
            <canvas id="Chart4"></canvas>
            <p>This graph shows the number of affected people per each million of the population. Countries with more than one million are shown only.</p>
            <script>
                var ctx4 = document.getElementById('Chart4').getContext('2d');
                chart[4] = new Chart(ctx4, $chart4data);
            </script>
        </div>

        $continent-list
        $country-list

        HTML

    html-template('/countries', 'Coronavirus in different countries', $content);
}

sub generate-continent-stats($cont, %countries, %per-day, %totals, %daily-totals) {
    say "Generating continent $cont...";

    my $chart1data = chart-pie(%countries, %per-day, %totals, %daily-totals, :$cont);
    my $chart2data = chart-daily(%countries, %per-day, %totals, %daily-totals, :$cont);
    my %chart3 = number-percent(%countries, %per-day, %totals, %daily-totals, :$cont);

    my $chart7data = daily-speed(%countries, %per-day, %totals, %daily-totals, :$cont);

    my $country-list = country-list(%countries, :$cont);
    my $continent-list = continent-list($cont);

    my $percent-str = %chart3<percent> ~ '&thinsp;%';
    my $population-str = %chart3<population>.round() ~ ' million';

    my $continent-name = %continents{$cont};
    my $continent-url = $continent-name.lc.subst(' ', '-');

    my $content = qq:to/HTML/;
        <h1>Coronavirus in {$continent-name}</h1>

        <div id="block2">
            <h2>Affected Population</h2>
            <div id="percent">{$percent-str}</div>
            <p>This is the part of confirmed infection cases against the total $population-str of its population.</p>
        </div>

        <div id="block1">
            <h2>Recovery Pie</h2>
            <canvas id="Chart1"></canvas>
            <p>The whole pie reflects the total number of confirmed cases of people infected by coronavirus in {$continent-name}.</p>
            <script>
                var ctx1 = document.getElementById('Chart1').getContext('2d');
                chart[1] = new Chart(ctx1, $chart1data);
            </script>
        </div>

        <div id="block3">
            <h2>Daily Flow</h2>
            <canvas id="Chart2"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale2" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale2" onclick="log_scale(this, 2)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale2"> Logarithmic scale</label>
            </p>
            <p>The height of a single bar is the total number of people suffered from Coronavirus in $continent-name and confirmed to be infected. It includes three parts: those who could or could not recover and those who are currently in the active phase of the disease.</p>
            <script>
                var ctx2 = document.getElementById('Chart2').getContext('2d');
                chart[2] = new Chart(ctx2, $chart2data);
            </script>
        </div>

        <div id="block7">
            <a name="speed"></a>
            <h2>Daily Speed</h2>
            <p>This graph shows the speed of growth (in %) over time in {$continent-name}. The main three parameters are the number of confirmed cases, the number of recoveries and failures. The orange line is the speed of changing of the number of active cases (i.e., of those, who are still ill).</p>
            <canvas id="Chart7"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale7" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale7" onclick="log_scale(this, 7)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale7"> Logarithmic scale</label>
            </p>
            <script>
                var ctx7 = document.getElementById('Chart7').getContext('2d');
                chart[7] = new Chart(ctx7, $chart7data);
            </script>
            <p>Note 1. In calculations, the 3-day moving average is used.</p>
            <p>Note 2. When the speed is positive, the number of cases grows every day. The line going down means that the speed decreeses, and while there may be more cases the next day, the disease spread is slowing down. If the speed goes below zero, that means that less cases registered today than yesterday.</p>
        </div>

        $continent-list
        $country-list

        HTML

    html-template("/$continent-url", "Coronavirus in $continent-name", $content);
}

sub generate-china-level-stats(%countries, %per-day, %totals, %daily-totals) {
    say 'Generating stats vs China...';

    my $chart6data = countries-vs-china(%countries, %per-day, %totals, %daily-totals);

    my $country-list = country-list(%countries);
    my $continent-list = continent-list();

    my $content = qq:to/HTML/;
        <h1>Countries vs China</h1>

        <script>
            var randomColorGenerator = function () \{
                return '#' + (Math.random().toString(16) + '0000000').slice(2, 8);
            \};
        </script>

        <div id="block6">
            <h2>Confirmed population timeline</h2>
            <p>On this graph, you see how the fraction (in %) of the confirmed infection cases changes over time in different countries or the US states.</p>
            <p>The almost-horizontal red line displays China. The number of confirmed infections in China almost stopped growing.</p>
            <p>Click on the bar in the legend to turn the line off and on.</p>
            <br/>
            <canvas id="Chart6"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale6" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale6" onclick="log_scale(this, 6)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale6"> Logarithmic scale</label>
            </p>
            <p>1. Note that only countries and US states with more than 1 million population are taken into account. The smaller countries such as <a href="/va">Vatican</a> or <a href="/sm">San Marino</a> would have shown too high nimbers due to their small population.</p>
            <p>2. The line for the country is drawn only if it reaches at least 75% of the corresponding maximum parameter in China.</p>
            <script>
                var ctx6 = document.getElementById('Chart6').getContext('2d');
                chart[6] = new Chart(ctx6, $chart6data);
            </script>
        </div>

        $continent-list
        $country-list

        HTML

    html-template('/vs-china', 'Countries vs China', $content);
}

sub countries-vs-china(%countries, %per-day, %totals, %daily-totals) {
    my %date-cc;
    for %per-day.keys -> $cc {
        for %per-day{$cc}.keys -> $date {
            %date-cc{$date}{$cc} = %per-day{$cc}{$date}<confirmed>;
        }
    }

    my %max-cc;
    # my $max = 0;

    my %data;
    for %date-cc.keys.sort -> $date {
        for %date-cc{$date}.keys -> $cc {
            next unless %countries{$cc};
            my $confirmed = %date-cc{$date}{$cc} || 0;
            %data{$cc}{$date} = sprintf('%.6f', 100 * $confirmed / (1_000_000 * +%countries{$cc}<population>));

            %max-cc{$cc} = %data{$cc}{$date};# if %max-cc{$cc} < %data{$cc}{$date};
            # $max = %max-cc{$cc} if $max < %max-cc{$cc};
        }
    }

    my @labels;
    my %dataset;

    for %date-cc.keys.sort -> $date {
        next if $date le '2020-02-20';
        @labels.push($date);

        for %date-cc{$date}.keys.sort -> $cc {
            next unless %max-cc{$cc};
            next if %countries{$cc}<population> < 1;

            next if %max-cc{$cc} < 0.75 * %max-cc<CN>;

            %dataset{$cc} = [] unless %dataset{$cc};
            %dataset{$cc}.push(%data{$cc}{$date});
        }
    }

    my @ds;
    for %dataset.sort: -*.value[*-1] -> $data {
        my $cc = $data.key;
        my $color = $cc eq 'CN' ?? 'red' !! 'RANDOMCOLOR';
        my %ds =
            label => %countries{$cc}<country>,
            data => $data.value,
            fill => False,
            borderColor => $color,
            lineTension => 0;
        push @ds, to-json(%ds);
    }

    my $json = q:to/JSON/;
        {
            "type": "line",
            "data": {
                "labels": LABELS,
                "datasets": [
                    DATASETS
                ]
            },
            "options": {
                "animation": false,
            }
        }
        JSON

    my $datasets = @ds.join(",\n");
    my $labels = to-json(@labels);

    $json ~~ s/DATASETS/$datasets/;
    $json ~~ s/LABELS/$labels/;
    $json ~~ s:g/\"RANDOMCOLOR\"/randomColorGenerator()/; #"

    return $json;
}

sub generate-country-stats($cc, %countries, %per-day, %totals, %daily-totals) {
    say "Generating $cc...";

    my $chart1data = chart-pie(%countries, %per-day, %totals, %daily-totals, :$cc);
    my $chart2data = chart-daily(%countries, %per-day, %totals, %daily-totals, :$cc);
    my $chart3 = number-percent(%countries, %per-day, %totals, %daily-totals, :$cc);

    my $chart7data = daily-speed(%countries, %per-day, %totals, %daily-totals, :$cc);

    my $country-list = country-list(%countries, :$cc);
    my $continent-list = continent-list(%countries{$cc}<continent>);

    my $country-name = %countries{$cc}<country>;
    my $population = +%countries{$cc}<population>;
    my $population-str = $population <= 1
        ?? sprintf('%i thousand', (1000 * $population).round)
        !! sprintf('%i million', $population.round);

    my $proper-country-name = $country-name;
    $proper-country-name = "the $country-name" if $cc ~~ /[US|GB|NL|DO|CZ]$/;

    my $content = qq:to/HTML/;
        <h1>Coronavirus in {$proper-country-name}</h1>

        <div id="block2">
            <h2>Affected Population</h2>
            <div id="percent">$chart3&thinsp;%</div>
            <p>This is the part of confirmed infection cases against the total $population-str of its population.</p>
        </div>

        <div id="block1">
            <h2>Recovery Pie</h2>
            <canvas id="Chart1"></canvas>
            <p>The whole pie reflects the total number of confirmed cases of people infected by coronavirus in {$proper-country-name}.</p>
            <script>
                var ctx1 = document.getElementById('Chart1').getContext('2d');
                chart[1] = new Chart(ctx1, $chart1data);
            </script>
        </div>

        <div id="block3">
            <h2>Daily Flow</h2>
            <canvas id="Chart2"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale2" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale2" onclick="log_scale(this, 2)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale2"> Logarithmic scale</label>
            </p>
            <p>The height of a single bar is the total number of people suffered from Coronavirus in {$proper-country-name} and confirmed to be infected. It includes three parts: those who could or could not recover and those who are currently in the active phase of the disease.</p>
            <script>
                var ctx2 = document.getElementById('Chart2').getContext('2d');
                chart[2] = new Chart(ctx2, $chart2data);
            </script>
        </div>

        <div id="block7">
            <a name="speed"></a>
            <h2>Daily Speed</h2>
            <p>This graph shows the speed of growth (in %) over time in {$proper-country-name}. The main three parameters are the number of confirmed cases, the number of recoveries and failures. The orange line is the speed of changing of the number of active cases (i.e., of those, who are still ill).</p>
            <canvas id="Chart7"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale7" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale7" onclick="log_scale(this, 7)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale7"> Logarithmic scale</label>
            </p>
            <script>
                var ctx7 = document.getElementById('Chart7').getContext('2d');
                chart[7] = new Chart(ctx7, $chart7data);
            </script>
            <p>Note 1. In calculations, the 3-day moving average is used.</p>
            <p>Note 2. When the speed is positive, the number of cases grows every day. The line going down means that the speed decreeses, and while there may be more cases the next day, the disease spread is slowing down. If the speed goes below zero, that means that less cases registered today than yesterday.</p>
        </div>

        $continent-list
        $country-list

        HTML

    html-template('/' ~ $cc.lc, "Coronavirus in {$proper-country-name}", $content);
}

sub country-list(%countries, :$cc?, :$cont?) {
    my $is_current = !$cc && !$cont ?? ' class="current"' !! '';
    my $html = qq{<p$is_current><a href="/">Whole world</a></p>};

    sub current-country($cc-code) {
        if $cc {
            return True if $cc ~~ /US/ && $cc-code eq 'US';
            return $cc eq $cc-code;
        }
        if $cont {
            return %countries{$cc-code}<continent> eq $cont;
        }

        return False;
    }

    my $us_html = '';
    for get-known-countries() -> $cc-code {
        next unless %countries{$cc-code};

        if $cc-code ~~ /US'/'/ {
            if $cc && $cc ~~ /US/ {
                my $path = $cc-code.lc;

                my $is_current = current-country($cc-code) ??  ' class="current"' !! '';

                my $state = %countries{$cc-code}<country>;
                $state ~~ s/US'/'//;
                $us_html ~= qq{<p$is_current><a href="/$path">} ~ $state ~ '</a></p>';
            }
        }
        else {
            my $path = $cc-code.lc;
            my $is_current = current-country($cc-code) ??  ' class="current"' !! '';
            $html ~= qq{<p$is_current><a href="/$path">} ~ %countries{$cc-code}<country> ~ '</a></p>';
        }
    }

    if $cc && $cc ~~ /US/ {
        $us_html = qq:to/USHTML/;
            <a name="states"></a>
            <h2>Coronavirus in the USA</h2>
            <p><a href="/us/#">Cumulative USA statistics</a></p>
            <div id="countries-list">
                $us_html
            </div>
        USHTML
    }

    return qq:to/HTML/;
        <div id="countries">
            $us_html
            <a name="countries"></a>
            <h2>Statistics per Country</h2>
            <p><a href="/">Whole world</a></p>
            <p><a href="/countries">More statistics on countries</a></p>
            <p><a href="/vs-china">Countries vs China</a></p>
            <div id="countries-list">
                $html
            </div>
        </div>
        HTML
}

sub continent-list($cont?) {
    my $is_current = !$cont ?? ' class="current"' !! '';
    my $html = qq{<p$is_current><a href="/">Whole world</a></p>};

    my $us_html = '';
    for %continents.keys.sort -> $cont-code {
        my $continent-name = %continents{$cont-code};
        my $continent-url = $continent-name.lc.subst(' ', '-');

        my $is_current = $cont && $cont-code eq $cont ??  ' class="current"' !! '';
        $html ~= qq{<p$is_current><a href="/$continent-url">} ~ $continent-name ~ '</a></p>';
    }

    return qq:to/HTML/;
        <div id="countries">
            <a name="continents"></a>
            <h2>Statistics per Continent</h2>
            <p><a href="/continents">Spread over the continents timeline</a></p>

            <div id="countries-list">
                $html
            </div>
        </div>
        HTML
}

sub countries-first-appeared(%countries, %per-day, %totals, %daily-totals) {
    my $sth = dbh.prepare('select confirmed, cc, date from per_day where confirmed != 0 and cc not like "%/%" order by date');
    $sth.execute();    

    my %data;
    for $sth.allrows(:array-of-hash) -> %row {
        %data{%row<date>}++;        
    }

    my @dates;
    my @n;
    my @percent;
    for %data.keys.sort -> $date {
        @dates.push($date);
        @n.push(%data{$date}); 
    }
    
    my $labels = to-json(@dates);

    my %dataset1 =
        label => 'The number of affected countries',
        data => @n,
        backgroundColor => 'lightblue',
        yAxisID => "axis1";
    my $dataset1 = to-json(%dataset1);

    my $json = q:to/JSON/;
        {
            "type": "bar",
            "data": {
                "labels": LABELS,
                "datasets": [
                    DATASET1
                ]
            },
            "options": {
                "animation": false,
                scales: {
                    yAxes: [
                        {
                            type: "linear",
                            display: true,
                            position: "left",
                            id: "axis1",
                            ticks: {
                                min: 0,
                                max: TOTALCOUNTRIES,
                                stepSize: 10
                            },
                            scaleLabel: {
                                display: true,
                                labelString: "The number of affected countries"
                            }
                        },
                        {
                            type: "linear",
                            display: true,
                            position: "right",
                            id: "axis2",
                            gridLines: {
                                drawOnChartArea: false
                            },
                            ticks: {
                                min: 0,
                                max: 100,
                                stepSize: 10
                            },
                            scaleLabel: {
                                display: true,
                                labelString: "Part of the total number of countries, in %"
                            }
                        }
                    ]
                }
            }
        }
        JSON

    $json ~~ s/DATASET1/$dataset1/;
    $json ~~ s/LABELS/$labels/;

    my $total-countries = +%countries.keys.grep(* !~~ /'/'/);
    my $current-n = @n[*-1];

    $json ~~ s/TOTALCOUNTRIES/$total-countries/;

    return 
        json => $json,
        total-countries => $total-countries,
        current-n => $current-n;
}

sub countries-appeared-this-day(%countries, %per-day, %totals, %daily-totals) {
    my $sth = dbh.prepare('select confirmed, cc, date from per_day where confirmed != 0 order by date');
    $sth.execute();

    my %cc;
    my %data;
    for $sth.allrows(:array-of-hash) -> %row {
        my $cc = %row<cc>;
        next if %cc{$cc};
        %cc{$cc} = 1; # "Bag" datatype should be used here

        %data{%row<date>}{$cc} = 1; # and here
    }

    my $html;    
    for %data.keys.sort.reverse -> $date {        
        $html ~= "<h4>{$date}</h4><p>";

        my @countries;
        for %data{$date}.keys.sort -> $cc {
            next unless %countries{$cc}; # TW is skipped here
            my $confirmed = %per-day{$cc}{$date}<confirmed>;
            @countries.push('<a href="/' ~ $cc.lc ~ '">' ~ %countries{$cc}<country> ~ "</a> ($confirmed)");
        }

        $html ~= @countries.join(', ');
        $html ~= '</p>';
    }

    return $html;
}

sub chart-pie(%countries, %per-day, %totals, %daily-totals, :$cc?, :$cont?) {
    my $confirmed = 0;
    my $failed = 0;
    my $recovered = 0;

    if $cc {
        $confirmed = %totals{$cc}<confirmed>;
        $failed    = %totals{$cc}<failed>;
        $recovered = %totals{$cc}<recovered>;
    }
    elsif $cont {
        for %totals.keys -> $cc-code {
            next unless %countries{$cc-code} && %countries{$cc-code}<continent> eq $cont;

            $confirmed += %totals{$cc-code}<confirmed>;
            $failed    += %totals{$cc-code}<failed>;
            $recovered += %totals{$cc-code}<recovered>;
        }
    }
    else {
        $confirmed = [+] %totals.values.map: *<confirmed>;
        $failed    = [+] %totals.values.map: *<failed>;
        $recovered = [+] %totals.values.map: *<recovered>;
    }

    my $active = $confirmed - $failed - $recovered;

    my $active-percent = $confirmed ?? sprintf('%i%%', (100 * $active / $confirmed).round) !! '';
    my $failed-percent = $confirmed ?? sprintf('%i%%', (100 * $failed / $confirmed).round) !! '';
    my $recovered-percent = $confirmed ?? sprintf('%i%%', (100 * $recovered / $confirmed).round) !! '';
    my $labels1 = qq{"Recovered $recovered-percent", "Failed to recover $failed-percent", "Active cases $active-percent"};

    my %dataset =
        label => 'Recovery statistics',
        data => [$recovered, $failed, $active],
        backgroundColor => ['green', 'red', 'orange'];
    my $dataset1 = to-json(%dataset);

    # JSON::Tiny refuses to put nested hashes as a single hash.
    my $json = q:to/JSON/;
        {
            "type": "pie",
            "data": {
                "labels": [LABELS1],
                "datasets": [
                    DATASET1
                ]
            },
            "options": {
                "animation": false
            }
        }
        JSON

    $json ~~ s/DATASET1/$dataset1/;
    $json ~~ s/LABELS1/$labels1/;

    return $json;
}

sub chart-daily(%countries, %per-day, %totals, %daily-totals, :$cc?, :$cont?) {
    my @dates;
    my @recovered;
    my @failed;
    my @active;

    for %daily-totals.keys.sort(*[0]) -> $date {
        @dates.push($date);

        my %data;
        if $cc {
            %data = %per-day{$cc}{$date};
        }
        elsif $cont {
            for %totals.keys -> $cc-code {
                next unless %countries{$cc-code} && %countries{$cc-code}<continent> eq $cont;

                %data<confirmed> += %per-day{$cc-code}{$date}<confirmed>;
                %data<failed>    += %per-day{$cc-code}{$date}<failed>;
                %data<recovered> += %per-day{$cc-code}{$date}<recovered>;
            }
        }
        else {
            %data = %daily-totals{$date};
        }

        @failed.push(%data<failed>);
        @recovered.push(%data<recovered>);

        @active.push([-] %data<confirmed recovered failed>);
    }

    my $labels = to-json(@dates);

    my %dataset1 =
        label => 'Recovered',
        data => @recovered,
        backgroundColor => 'green';
    my $dataset1 = to-json(%dataset1);

    my %dataset2 =
        label => 'Failed to recover',
        data => @failed,
        backgroundColor => 'red';
    my $dataset2 = to-json(%dataset2);

    my %dataset3 =
        label => 'Active cases',
        data => @active,
        backgroundColor => 'orange';
    my $dataset3 = to-json(%dataset3);

    my $json = q:to/JSON/;
        {
            "type": "bar",
            "data": {
                "labels": LABELS,
                "datasets": [
                    DATASET2,
                    DATASET3,
                    DATASET1
                ]
            },
            "options": {
                "animation": false,
                "scales": {
                    "xAxes": [{
                        "stacked": true,
                    }],
                    "yAxes": [{
                        "stacked": true
                    }]
                }
            }
        }
        JSON

    $json ~~ s/DATASET1/$dataset1/;
    $json ~~ s/DATASET2/$dataset2/;
    $json ~~ s/DATASET3/$dataset3/;
    $json ~~ s/LABELS/$labels/;

    return $json;
}

multi sub number-percent(%countries, %per-day, %totals, %daily-totals) {
    my $confirmed = [+] %totals.values.map: *<confirmed>;

    my $percent = '%.2g'.sprintf(100 * $confirmed / $world-population);

    return $percent;
}

multi sub number-percent(%countries, %per-day, %totals, %daily-totals, :$cc!) {
    my $confirmed = %totals{$cc}<confirmed>;

    my $population = %countries{$cc}<population>;
    return 0 unless $population;

    $population *= 1_000_000;
    my $percent = '%.2g'.sprintf(100 * $confirmed / $population);

    return '<&thinsp;0.001' if $percent ~~ /e/;

    return $percent;
}

multi sub number-percent(%countries, %per-day, %totals, %daily-totals, :$cont!) {
    my $confirmed = 0;
    my $population = 0;

    for %countries.keys -> $cc {
        next unless %countries{$cc}<continent>;
        next unless %countries{$cc}<continent> eq $cont;

        $population += %countries{$cc}<population>;

        next unless %totals{$cc};
        $confirmed += %totals{$cc}<confirmed>;
    }

    my $percent = '%.2g'.sprintf(100 * $confirmed / (1_000_000 * $population));

    $percent = '<&thinsp;0.001' if $percent ~~ /e/;

    return
        percent => $percent,
        population => $population;
}

sub countries-per-capita(%countries, %per-day, %totals, %daily-totals) {
    my %per-mln;
    for get-known-countries() -> $cc {
        my $population-mln = %countries{$cc}<population>;

        next if $population-mln < 1;
        
        %per-mln{$cc} = sprintf('%.2f', %totals{$cc}<confirmed> / $population-mln);
    }

    my @labels;
    my @recovered;
    my @failed;
    my @active;

    my $count = 0;
    for %per-mln.sort(+*.value).reverse -> $item {
        last if ++$count > 30;

        my $cc = $item.key;
        my $population-mln = %countries{$cc}<population>;

        @labels.push(%countries{$cc}<country>);

        my $per-capita-confirmed = $item.value;
        
        my $per-capita-failed = %totals{$cc}<failed> / $population-mln;
        $per-capita-failed = 0 if $per-capita-failed < 0;
        @failed.push('%.2f'.sprintf($per-capita-failed));

        my $per-capita-recovered = %totals{$cc}<recovered> / $population-mln;
        $per-capita-recovered = 0 if $per-capita-recovered < 0;
        @recovered.push('%.2f'.sprintf($per-capita-recovered));

        @active.push('%.2f'.sprintf(($per-capita-confirmed - $per-capita-failed - $per-capita-recovered)));
    }

    my $labels = to-json(@labels);

    my %dataset1 =
        label => 'Recovered',
        data => @recovered,
        backgroundColor => 'green';
    my $dataset1 = to-json(%dataset1);

    my %dataset2 =
        label => 'Failed to recover',
        data => @failed,
        backgroundColor => 'red';
    my $dataset2 = to-json(%dataset2);

    my %dataset3 =
        label => 'Active cases',
        data => @active,
        backgroundColor => 'orange';
    my $dataset3 = to-json(%dataset3);

    my $json = q:to/JSON/;
        {
            "type": "horizontalBar",
            "data": {
                "labels": LABELS,
                "datasets": [
                    DATASET2,
                    DATASET3,
                    DATASET1
                ]
            },
            "options": {
                "animation": false,
                "scales": {
                    "xAxes": [{
                        "stacked": true,
                    }],
                    "yAxes": [{
                        "stacked": true,
                        "ticks": {
                            "autoSkip": false
                        }
                    }],
                }
            }
        }
        JSON

    $json ~~ s/DATASET1/$dataset1/;
    $json ~~ s/DATASET2/$dataset2/;
    $json ~~ s/DATASET3/$dataset3/;
    $json ~~ s/LABELS/$labels/;
    
    return $json;
}

sub generate-continent-graph(%countries, %per-day, %totals, %daily-totals) {
    my $chart8data = continent-joint-graph(%countries, %per-day, %totals, %daily-totals);

    my $country-list = country-list(%countries);
    my $continent-list = continent-list();

    my $content = qq:to/HTML/;
        <h1>Coronavirus Spread over the Continents</h1>

        <div id="block3">
            <h2>Active Cases Timeline</h2>
            <p>This bar chart displays the timeline of the number of active cases (thus, confirmed minus failed to recovered minus recovered). The gold bars are those reflecting <a href="/asia">Asia</a> (mostly, <a href="/cn">China</a>). The blue bars correspond to the number of active cases in <a href="/europe">Europe</a>.</p>
            <canvas id="Chart8"></canvas>
            <p class="left">
                <label class="toggle-switchy" for="logscale8" data-size="xs" data-style="rounded" data-color="blue">
                    <input type="checkbox" id="logscale8" onclick="log_scale(this, 8)">
                    <span class="toggle">
                        <span class="switch"></span>
                    </span>
                </label>
                <label for="logscale8"> Logarithmic scale</label>
            </p>
            <script>
                var ctx8 = document.getElementById('Chart8').getContext('2d');
                chart[8] = new Chart(ctx8, $chart8data);
            </script>
        </div>

        $continent-list
        $country-list

        HTML

    html-template('/continents', 'Coronavirus over the Continents', $content);
}

sub continent-joint-graph(%countries, %per-day, %totals, %daily-totals) {
    my @labels;
    my %datasets;
    for %daily-totals.keys.sort -> $date {
        push @labels, $date;

        my %day-data;
        for %per-day.keys -> $cc {
            next unless %countries{$cc} && %countries{$cc}<continent>;

            my $continent = %countries{$cc}<continent>;

            my $confirmed = %per-day{$cc}{$date}<confirmed> || 0;
            my $failed = %per-day{$cc}{$date}<failed> || 0;
            my $recovered = %per-day{$cc}{$date}<recovered> || 0;

            %day-data{$continent} += $confirmed - $failed - $recovered;
        }

        for %day-data.keys -> $cont {
            %datasets{$cont} = [] unless %datasets{$cont};
            %datasets{$cont}.push(%day-data{$cont});
        }
    }

    my $labels = to-json(@labels);

    my %continent-color =
        AF => '#f5494d', AS => '#c7b53e', EU => '#477ccc',
        NA => '#d256d7', OC => '#40d8d3', SA => '#35ad38';

    my %json;
    for %datasets.keys -> $cont {
        my %ds =
            label => %continents{$cont},
            data => %datasets{$cont},
            backgroundColor => %continent-color{$cont};
        %json{$cont} = to-json(%ds);
    }

    my $json = q:to/JSON/;
        {
            "type": "bar",
            "data": {
                "labels": LABELS,
                "datasets": [
                    DATASETAF,
                    DATASETAS,
                    DATASETEU,
                    DATASETNA,
                    DATASETSA,
                    DATASETOC
                ]
            },
            "options": {
                "animation": false,
            }
        }
        JSON

    $json ~~ s/LABELS/$labels/;

    for %continents.keys -> $cont {
        $json ~~ s/DATASET$cont/%json{$cont}/;
    }

    return $json;
}

sub daily-speed(%countries, %per-day, %totals, %daily-totals, :$cc?, :$cont?) {
    my @labels;
    my @confirmed;
    my @failed;
    my @recovered;
    my @active;

    my %data;

    if $cc {
        %data = %per-day{$cc};
    }
    elsif $cont {
        for %per-day.keys -> $cc-code {
            next unless %countries{$cc-code} && %countries{$cc-code}<continent> eq $cont;

            for %per-day{$cc-code}.keys -> $date {
                %data{$date} = Hash.new unless %data{$date};

                %data{$date}<confirmed> += %per-day{$cc-code}{$date}<confirmed>;
                %data{$date}<failed>    += %per-day{$cc-code}{$date}<failed>;
                %data{$date}<recovered> += %per-day{$cc-code}{$date}<recovered>;
            }
        }
    }
    else {
        %data = %daily-totals;
    }

    my @dates = %data.keys.sort;

    my $skip-days = $cc ?? 0 !! 0;
    my $skip-days-confirmed = $skip-days;
    my $skip-days-failed    = $skip-days;
    my $skip-days-recovered = $skip-days;
    my $skip-days-active    = $skip-days;

    my $avg-width = 3;

    for $avg-width ..^ @dates -> $index {
        @labels.push(@dates[$index]);

        my $day0 = @dates[$index];
        my $day1 = @dates[$index - 1];
        my $day2 = @dates[$index - 2];
        my $day3 = @dates[$index - 3];

        # Skip the first days in the graph to avoid a huge peak after first data appeared;
        $skip-days-confirmed-- if %data{$day0}<confirmed> && $skip-days-confirmed;
        $skip-days-failed--    if %data{$day0}<failed> && $skip-days-failed;
        $skip-days-recovered-- if %data{$day0}<recovered> && $skip-days-recovered;
        $skip-days-active--    if [-] %data{$day0}<confirmed failed recovered> && $skip-days-active;

        my $r = (%data{$day0}<confirmed> + %data{$day1}<confirmed> + %data{$day2}<confirmed>) / 3;
        my $l = (%data{$day1}<confirmed> + %data{$day2}<confirmed> + %data{$day3}<confirmed>) / 3;
        my $delta = $r - $l;
        my $speed = $l ?? sprintf('%.2f', 100 * $delta / $l) !! 0;
        @confirmed.push($skip-days-confirmed ?? 0 !! $speed);

        $r = (%data{$day0}<failed> + %data{$day1}<failed> + %data{$day2}<failed>) / 3;
        $l = (%data{$day1}<failed> + %data{$day2}<failed> + %data{$day3}<failed>) / 3;
        $delta = $r - $l;
        $speed = $l ?? sprintf('%.2f', 100 * $delta / $l) !! 0;
        @failed.push($skip-days-failed ?? 0 !! $speed);

        $r = (%data{$day0}<recovered> + %data{$day1}<recovered> + %data{$day2}<recovered>) / 3;
        $l = (%data{$day1}<recovered> + %data{$day2}<recovered> + %data{$day3}<recovered>) / 3;
        $delta = $r - $l;
        $speed = $l ?? sprintf('%.2f', 100 * $delta / $l) !! 0;
        @recovered.push($skip-days-recovered ?? 0 !! $speed);

        $r = ([-] %data{$day0}<confirmed failed recovered> + [-] %data{$day1}<confirmed failed recovered> + [-] %data{$day2}<confirmed failed recovered>) / 3;
        $l = ([-] %data{$day1}<confirmed failed recovered> + [-] %data{$day2}<confirmed failed recovered> + [-] %data{$day3}<confirmed failed recovered>) / 3;
        $delta = $r - $l;
        $speed = $l ?? sprintf('%.2f', 100 * $delta / $l) !! 0;
        @active.push($skip-days-active ?? 0 !! $speed);
    }

    my $trim-left = 3;

    my $labels = to-json(trim-data(@labels, $trim-left));

    my %dataset0 =
        label => 'Confirmed total',
        data => trim-data(moving-average(@confirmed, $avg-width), $trim-left),
        fill => False,
        lineTension => 0,
        borderColor => 'lightblue';
    my $dataset0 = to-json(%dataset0);

    my %dataset1 =
        label => 'Recovered',
        data => trim-data(moving-average(@recovered, $avg-width), $trim-left),
        fill => False,
        lineTension => 0,
        borderColor => 'green';
    my $dataset1 = to-json(%dataset1);

    my %dataset2 =
        label => 'Failed to recover',
        data => trim-data(moving-average(@failed, $avg-width), $trim-left),
        fill => False,
        lineTension => 0,
        borderColor => 'red';
    my $dataset2 = to-json(%dataset2);

    my %dataset3 =
        label => 'Active cases',
        data => trim-data(moving-average(@active, $avg-width), $trim-left),
        fill => False,
        lineTension => 0,
        borderColor => 'orange';
    my $dataset3 = to-json(%dataset3);

    my $json = q:to/JSON/;
        {
            "type": "line",
            "data": {
                "labels": LABELS,
                "datasets": [
                    DATASET0,
                    DATASET2,
                    DATASET3,
                    DATASET1
                ]
            },
            "options": {
                "animation": false,
                "scales": {
                    "yAxes": [{
                        "type": "linear",
                    }],
                }
            }
        }
        JSON

    $json ~~ s/DATASET0/$dataset0/;
    $json ~~ s/DATASET1/$dataset1/;
    $json ~~ s/DATASET2/$dataset2/;
    $json ~~ s/DATASET3/$dataset3/;
    $json ~~ s/LABELS/$labels/;

    return $json;
}

sub moving-average(@in, $width = 3) {
    my @out;

    @out.push(0) for ^$width;
    for $width ..^ @in -> $index {
        my $avg = [+] @in[$index - $width .. $index];
        @out.push($avg / $width);
    }

    return @out;
}

sub trim-data(@data, $trim-length) {
    return @data[$trim-length .. *];
}

sub html-template($path, $title, $content) {
    my $style = q:to/CSS/;
        CSS

    my $script = q:to/JS/;
        var chart = new Array();
        function log_scale(input, n) {
            chart[n].options.scales.yAxes[0].type = input.checked ? 'logarithmic' : 'linear';
            chart[n].update();
            input.blur();
        }
        JS

    my $ga = q:to/GA/;
        <script async src="https://www.googletagmanager.com/gtag/js?id=UA-160707541-1"></script>
        <script>
            window.dataLayer = window.dataLayer || [];
            function gtag(){dataLayer.push(arguments);}
            gtag('js', new Date());
            gtag('config', 'UA-160707541-1');
        </script>
        GA

    my $speed-url = $path ~~ / 'vs-china' | countries | 404 / ?? '/#speed' !! '#speed';

    my $template = qq:to/HTML/;
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>$title | Coronavirus COVID-19 Observer</title>

            $ga

            <script src="/Chart.min.js"></script>
            <link href="https://fonts.googleapis.com/css?family=Nanum+Gothic&display=swap" rel="stylesheet">
            <link rel="stylesheet" type="text/css" href="/main.css?v=3">
            <style>
                $style
            </style>

            <script>
                $script
            </script>
        </head>
        <body>
            <p>
                <a href="/">Home</a>
                |
                New:
                <a href="/#continents">Continents</a>
                |
                <a href="/continents">Spread over continents</a>
            </p>
            <p>
                <a href="#countries">Countries</a>
                |
                <a href="/countries">Affected countries</a>
                |
                <a href="/vs-china">Countries vs China</a>
                |
                <a href="/us#states">US states</a>
                |
                <a href="$speed-url">Daily speed</a>
            </p>

            $content

            <div id="about">
                <p>Based on <a href="https://github.com/CSSEGISandData/COVID-19">data</a> collected by the Johns Hopkins University Center for Systems Science and Engineering.</p>
                <p>This website presents the very same data but from a less-panic perspective. Updated daily around 8 a.m. European time.</p>
                <p>Created by <a href="https://andrewshitov.com">Andrew Shitov</a>. Twitter: <a href="https://twitter.com/andrewshitov">\@andrewshitov</a>. Source code: <a href="https://github.com/ash/covid.observer">GitHub</a>. Powered by <a href="https://raku.org">Raku</a>.</p>
            </div>
        </body>
        </html>
        HTML    

    mkdir("www$path");
    my $filepath = "./www$path/index.html";
    given $filepath.IO.open(:w) {
        .say: $template
    }
}
