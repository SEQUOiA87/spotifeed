require './spotify'

class Redis
  def cache(key, expire = nil)
    if (value = get(key)).nil?
      value = yield(self)
      set(key, value)
      expire(key, expire) if expire
      value
    else
      value
    end
  end
end

$redis = Redis.new
$timeout_seconds = 300 # 5 minutes

class Spotifeed < Sinatra::Base
  configure :development do
    register Sinatra::Reloader
  end

  attr_reader :spotify

  def initialize
    super
    @spotify = Spotify.new
  end

  get '/' do
    File.read(File.join('public', 'index.html'))
  end

  get '/:show_id' do
    show_id = params[:show_id] || ENV['SHOW_ID']
    return '' unless show_id =~ /\A\w{22}\z/

    show = $redis.cache("show:#{show_id}", $timeout_seconds) do
      # puts "get show with id #{show_id} from Spotify API"
      JSON.generate spotify.conn.get("shows/#{show_id}?market=US").body
    end
    show = JSON.parse(show)
    return 'Not a valid show' if show['error']

    episodes = $redis.cache("episodes:#{show_id}", $timeout_seconds) do
      # puts "get episodes of show with id #{show_id} from Spotify API"
      request = "shows/#{show_id}/episodes?market=US&limit=50"
      episodeList = []
      loop do
        data = spotify.conn.get(request).body

        episodeList += data['items']
    
        break if !data['next']
        request = data['next'].split('/v1/').last
      end
      JSON.generate episodeList
    end
    episodes = JSON.parse(episodes)
    return 'No episodes found' if episodes.empty?

    content_type 'application/rss+xml; charset=utf-8'
    RSS::Maker::RSS20.make do |rss|
      rss.channel.title = show['name']
      rss.channel.description = show['description']
      rss.channel.itunes_summary = show['description']
      rss.channel.link = show.dig('external_urls', 'spotify')
      rss.channel.author = show['publisher']
      rss.channel.itunes_author = show['publisher']
      rss.channel.language = show['languages'].first

      rss.image.url = show.dig('images', 0, 'url')
      rss.image.title = show['name']
      rss.channel.itunes_image = show.dig('images', 0, 'url')

      rss.channel.updated = Time.parse(show.dig('episodes', 'items', 0, 'release_date') || '01-01-2020').to_s
      # rss.channel.generator = 'Spotifeed'

      rss.items.do_sort = true
      episodes.each do |episode|
        rss.items.new_item do |item|
          duration_secs = (episode['duration_ms'] / 1000).floor

          item.guid.content = episode['uri']
          item.title = episode['name']
          item.description = episode['description']
          item.date = Time.parse(episode['release_date'] || '01-01-2020').to_s

          item.itunes_subtitle = episode['description']
          item.itunes_image = episode.dig('images', 0, 'url')
          item.itunes_duration = "%02d:%02d:%02d" % [duration_secs / 3600, duration_secs / 60 % 60, duration_secs % 60]
          item.itunes_explicit = episode['explicit']

          item.link = episode.dig('external_urls', 'spotify')
          item.enclosure.url = "https://anon-podcast.scdn.co/#{episode['audio_preview_url'].split('/').last}"
          item.enclosure.length = duration_secs
          item.enclosure.type = 'audio/mpeg'
        end
      end
    end.to_s
  end
end
