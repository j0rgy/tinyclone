%w(rubygems sinatra haml uri rest_client data_mapper xmlsimple ./dirty_words).each { |lib| require lib}

disable :show_exceptions
enable :inline_templates # Lets us put the haml templates in this file.

# View the main page
get '/' do haml :index end

# Shorten a URL
post '/' do
  uri = URI::parse(params[:original])

  # If a custom parameter is found, use it, otherwise don't
  custom = params[:custom].empty? ? nil : params[:custom]

  # Make sure the input is a vlid HTTP or HTTPS url
  raise "Invalid URL" unless uri.kind_of? URI::HTTP or uri.kind_of? URI::HTTPS
  
  # Use the 'shorten' method in the 'Link' class to create a 'Link' object, which is then passed to the view by '@link'
  @link = Link.shorten(params[:original], custom)
  haml :index
end

# Redirect from a short URL to original URL
get '/:short_url' do

  # Look up the identifier and return the long url
  link = Link.first(:identifier => params[:short_url])

  # Record a visit to the link
  link.visits << Visit.create(:ip => get_remote_ip(env))
  link.save

  # Redirect to the original url
  redirect link.url.original, 301
end

# Get the IP address
def get_remote_ip(env)
  if addr = env['HTTP_X_FORWARDED_FOR']
    addr.split(',').first.strip
  else
    env['REMOTE_ADDR']
  end
end

# Next is a group of routes that show the information on the short URL
# We are grouping three different routes under a single block. This is possible under Sinatra because each route is a method being called and not being defined in the code. We grouped the routes by placing them in an array and iterating them with a get call.

['/info/:short_url', '/info/:short_url/:num_of_days', '/info/:short_url/:num_of_days/:map'].each do |path|
  get path do
    # Establish that the short URL is an existing link in the database.
    @link = Link.first(:identifier => params[:short_url])
    riase 'This link is not defined yet' unless @link
    @num_of_days = (params[:num_of_days] || 15).to_i
    @count_days_bar = Visit.count_days_bar(params[:short_url], @num_of_days)
    chart = Visit.count_country_chart(params[:short_url], params[:map] || 'world')
    @count_country_map = chart[:map]
    @count_country_bar = chart[:bar]
    haml :info
  end
end

error do haml :index end

DataMapper.setup(:default, ENV['DATABASE_URL'] || 'mysql://root:root@localhost/tinyclone')
#DataMapper::Model.raise_on_save_failure = true
class Url # The actual URL
  # Requirements
  # - Store the original URL

  include DataMapper::Resource
  property :id, Serial  # An auto-increment integer key
  property :original, String  # A string with the 'original' long Url
  
  belongs_to :link, :required => false
end

class Link # The short link
  # Requirements
  # - Create a shortened link that points to a long URL
  include DataMapper::Resource
  property :identifier, String, :key => true # The 'short' Url identifier
  property :created_at, DateTime # A time stamp for when the link was created
  
  has 1, :url       # The 'Url' class belongs to 'Link'
  has n, :visits    # The 'Link' has many 'Visits'

  # Shorten the link
  # We pass in an original URL and optionally a custom label we want for the short URL
  def self.shorten(original, custom=nil)
    # First, we check if the URL is already shortened. Look for the first URL that matches the 'original' long URL.
    url = Url.first(:original => original)
    # If it is, we just return the link.
    return url.link if url
    # If it's not found, we create a new link
    link = nil

    # If a custom label is provided...
    if custom
      # We check if the label is already in use
      raise 'Someone has already taken this custom URL, sorry' unless Link.first(:identifier => custom).nil?
      # We also check that the label is not in our list of bad words
      raise 'This custom URL is not allowed because of profanity' if DIRTY_WORDS.include? custom
      transaction do |txn|
        link = Link.new(:identifier => custom)
        link.url = Url.create(:original => original)
        link.save
      end
    else
      transaction do |txn|
        link = create_link(original)
      end
    end

    return link
  end

  def self.create_link(original)
    # We use a recursive method to create the link. Without a custom label, we will ues the record ID
    # as the identifier for the Link object. If coincidentally the custom label is in the list of banned
    # words or if the record ID created is the same as an existing custom label, we want to create
    # another Url object to represent the new Link object.
    url = Url.create(:original => original)
    if Link.first(:identifier => url.id.to_s(36)).nil? or !DIRTY_WORDS.include? url.id.to_s(36)
      link = Link.new(:identifier => url.id.to_s(36))
      link.url = url
      link.save
      return link
    else
      create_link(original)
    end
  end

end

class Visit
  # Requirements
  # - Store the number of visits to a short URL (link)
  # - Retrieve usage charts and statistics

  include DataMapper::Resource
  property :id, Serial
  property :created_at, DateTime
  property :ip, String
  property :country, String

  # After the 'Visit' object is created, set the country
  after :create, :set_country

  # Send the HostIP IP geocoding API the IP address and get an XML document
  # that contains information on the country where the client comes from in
  # geocoded XML.

  # Using XmlSimple, we parse that document and set the country code.
  # The country information is in the form of ISO 3166-1 country codes,
  # which are two letter abbreviations of country names. Singapore
  # would be SG, France would be FR, the United States would be US.

  def set_country
    xml = RestClient.get "http://api.hostip.info/get_xml.php?ip=#{ip}"
    self.country = XmlSimple.xml_in(xml.to_s, {'ForceArray' => false })['featureMember']['Hostip']['countryAbbrev']
    self.save
  end

  # Next, we want to get the visit statistics after storing the visit
  # information. We use two methods to do this one that get the
  # statistics by date, and another by country of origin.

  def self.count_by_date_with(identifier, num_of_days)

    # We use SQL directly on the table to get the data for the range
    # of dates we want. This results in an array of Ruby Struct objects
    # that contain the info we want.

    visits = repository(:default).adapter.query("SELECT date(created_at) as date, count(*) as count FROM visits where link_identifier= '#{identifier}' and created_at between CURRENT_DATE-#{num_of_days} and CURRENT_DATE+1 group by date(created_at)")

    # However, we can't use this directly because there would be some dates
    # without visits, and the SQL doesn't return empty dates. 

    # We create a contiguous list of dates and for each date we put in
    # the visit count if it is not 0, and 0 if there are no visits.

    # The result we return from this method is a hash table of data
    # with the date as the key and the count as the value.

    dates = (Date.today-num_of_days..Date.today)
    results = {}
    dates.each { |date|
      visits.each { |visit| results[date] = visit.count if visit.date == date }
      results[date] = 0 unless results[date]
    }
    results.sort.reverse
  end

  # The 'count_by_country' method is simpler -- we just get the count
  # per country.

  def self.count_by_country_with(identifier)
    repository(:default).adapter.query("SELECT country, count(*) as count FROM visits where link_identifier = '#{identifier}' group by country")
  end

  # We use two methods to return the charts we need.

  # The 'count_days_bar' method takes the identifier and the number of days we want
  # to display the info on and returns a Google Chart API URL that shows the chart
  # we want: a vertical bar chart that shows the visit count by date.

  def self.count_days_bar(identifier, num_of_days)
    visits = count_by_date_with(identifier, num_of_days)
    data, labels = [], []
    visits.each { |visit| data << visit[1]; labels << "#{visit[0].day}/#{visit[0].month}" }
    "http://chart.apis.google.com/chart?chs=820x180&cht=bvs&chxt=x&chco=a4b3f4&chm=N,000,000,0,-1,11&chxl=0:|#{labels.join('|')}&chds=0,#{data.sort.last+10}&chd=t:#{data.join(',')}"
  end

  # The 'count_country_chart' method takes in the identifier and the geographical
  # zoom-in of the map we want and returns two charts.

  # The first chart is a horizontal chart showing the number of visits by country and the second chart is a map visualizing the countries where the visits came from. 
  def self.count_country_chart(identifier, map)
    countries, count = [], []
    count_by_country_with(identifier).each {|visit| countries << visit.country; count << visit.count}
    chart = {}
    chart[:map] = "http://chart.apis.google.com/chart?chs=440x220&cht=t&chtm=#{map}&chco=FFFFFF,a4b3f4,0000FF&chld=#{countries.join('')}&chd=t:#{count.join(',')}"
    chart[:bar] = "http://chart.apis.google.com/chart?chs=320x240&cht=bhs&chco=a4b3f4&chm=N,000000,0,-1,11&chbh=a&chd=t:#{count.join(',')}&chxt=x,y&chxl=1:|#{countries.reverse.join('|')}"
    return chart
  end

end

DataMapper.finalize.auto_upgrade!
DataMapper.auto_migrate!

__END__

-# = Tells Sinatra that anything after the __END__ will not be parsed

@@ layout
!!! 1.1
%html
  %head
    %title TinyClone
    %link{:rel => 'stylesheet', :href => 'http://www.blueprintcss.org/blueprint/screen.css', :type => 'text/css'}
    %body
      .container
        %p
        = yield

@@ index
%h1.title TinyClone

-# = If there is a link present, display what it has been shortened to
- unless @link.nil?
  .success
    %code= @link.url.original
    has been shortened to
    %a{:href => "/#{@link.identifier}"}
      = "http://tinyclonej0rg.herokuapp.com/#{@link.identifier}"
    %br
    Go to
    %a{:href => "/info/#{@link.identifier}"}
      = "http://tinyclonej0rg.herokuapp.com/info/#{@link.identifier}"
    to get more information about this link.

-# = If there's an error, display the error    
- if env['sinatra.error']
  .error= env['sinatra.error']

-# = Display the link shortening form 
%form{:method => 'post', :action => '/'}
  Shorten this:
  %input{:type => 'text', :name => 'original', :size => '70'}
  %input{:type => 'submit', :value => 'now!'}
  %br
  to http://tinyclonej0rg.herokuapp.com/
  %input{:type => 'text', :name => 'custom', :size => '20'}
  (optional)
%p
%small copyright &copy;
%a{:href => 'http://blog.saush.com'}
  Chang Sau Sheong
%p
  %a{:href => 'http://github.com/sausheong/tinyclone'}
    Full source code

-# = Display info about a URL
@@ info
%h1.title Information
.span-3 Original
.span-21.last= @link.url.original
.span-3 Shortened
.span-21.last
  %a{:href => "/#{@link.identifier}"}
    = "http://tinyclonej0rg.herokuapp.com/#{@link.identifier}"
.span-3 Date created
.span-21.last= @link.created_at
.span-3 Number of visits
.span-21.last= "#{@link.visits.size.to_s} visits"

%h2= "Number of visits in the past #{@num_of_days} days"
- %w(7 14 21 30).each do |num_days|
  %a{:href => "/info/#{@link.identifier}/#{num_days}"}
    ="#{num_days} days "
  |
%p
.span-24.last
  %img{:src => @count_days_bar}

%h2 Number of visits by country
- %w(world usa asia europe africa middle_east south_america).each do |loc|
  %a{:href => "/info/#{@link.identifier}/#{@num_of_days.to_s}/#{loc}"}
    =loc
  |
%p
.span-12
  %img{:src => @count_country_map}
.span-12.last
  %img{:src => @count_country_bar}
%p