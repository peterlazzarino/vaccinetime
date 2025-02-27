require 'optparse'
require 'sentry-ruby'

require_relative 'lib/multi_logger'
require_relative 'lib/storage'
require_relative 'lib/slack'
require_relative 'lib/twitter'

# Sites
require_relative 'lib/sites/vaccinate_ri'
require_relative 'lib/sites/cvs'

UPDATE_FREQUENCY = ENV['UPDATE_FREQUENCY']&.to_i || 60 # seconds

SCRAPERS = {
  'cvs' => Cvs,
  'vaccinate_ri' => VaccinateRI,
}.freeze

def all_clinics(scrapers, storage, logger)
  if scrapers == 'all'
    SCRAPERS.values.each do |scraper_module|
      yield scraper_module.all_clinics(storage, logger)
    end
  else
    scrapers.each do |scraper|
      scraper_module = SCRAPERS[scraper]
      raise "Module #{scraper} not found" unless scraper_module

      yield scraper_module.all_clinics(storage, logger)
    end
  end
end

def main(scrapers: 'all')
  environment = ENV['ENVIRONMENT'] || 'dev'

  if ENV['SENTRY_DSN']
    Sentry.init do |config|
      config.dsn = ENV['SENTRY_DSN']
      config.environment = environment
    end
  end

  logger = MultiLogger.new(
    Logger.new($stdout),
    Logger.new("log/#{environment}.txt", 'daily')
  )
  storage = Storage.new
  slack = SlackClient.new(logger)
  twitter = TwitterClient.new(logger)

  logger.info "[Main] Update frequency is set to every #{UPDATE_FREQUENCY} seconds"

  if ENV['SEED_REDIS']
    logger.info '[Main] Seeding redis with current appointments'
    all_clinics(scrapers, storage, logger) { |clinics| clinics.each(&:save_appointments) }
    logger.info '[Main] Done seeding redis'
    sleep(UPDATE_FREQUENCY)
  end

  loop do
    logger.info '[Main] Started checking'
    all_clinics(scrapers, storage, logger) do |clinics|
      slack.post(clinics)
      twitter.post(clinics)

      clinics.each(&:save_appointments)
    end

    logger.info '[Main] Done checking'
    sleep(UPDATE_FREQUENCY)
  end

rescue => e
  Sentry.capture_exception(e)
  logger.error "[Main] Error: #{e}"
  raise
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby run.rb [options]"

  opts.on('-s', '--scrapers SCRAPER1,SCRAPER2', Array, "Scraper to run, choose from: #{SCRAPERS.keys.join(', ')}") do |s|
    options[:scrapers] = s
  end
end.parse!

main(**options)
