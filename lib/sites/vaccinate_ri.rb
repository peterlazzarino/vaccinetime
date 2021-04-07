require 'date'
require 'nokogiri'
require 'open-uri'
require 'rest-client'
require 'sentry-ruby'

require_relative '../sentry_helper'
require_relative './base_clinic'

module VaccinateRI
  BASE_URL = "https://www.vaccinateri.org/clinic/search".freeze

  def self.all_clinics(storage, logger)
    unconsolidated_clinics(storage, logger).each_with_object({}) do |clinic, h|
      if h[clinic.title]
        h[clinic.title].appointments += clinic.appointments
      else
        h[clinic.title] = clinic
      end
    end.values
  end

  def self.unconsolidated_clinics(storage, logger)
    page_num = 1
    clinics = []
    SentryHelper.catch_errors(logger, 'VaccinateRI', on_error: clinics) do
      loop do
        raise "Too many pages: #{page_num}" if page_num > 100

        logger.info "[VaccinateRI] Checking page #{page_num}"
        page = Page.new(page_num, storage, logger)
        page.fetch
        return clinics if page.waiting_page

        clinics += page.clinics
        return clinics if page.final_page?

        page_num += 1
        sleep(2)
      end
    end
    clinics
  end

  class Page
    CLINIC_PAGE_IDENTIFIER = /Find a Vaccination Clinic/.freeze
    COOKIE_SITE = 'vaccinate-ri'.freeze

    attr_reader :waiting_page

    def initialize(page, storage, logger)
      @page = page
      @storage = storage
      @logger = logger
      @waiting_page = false
    end

    def fetch
      cookies = get_cookies     
      @logger.info BASE_URL + "&page=#{@page}"
      response = RestClient.get(BASE_URL + "?page=#{@page}", cookies: cookies).body 

      @doc = Nokogiri::HTML(response)
    end

    def get_cookies
      existing_cookies = @storage.get_cookies(COOKIE_SITE) || {}
      cookies = existing_cookies['cookies']
      if cookies
        cookie_expiration = Time.parse(existing_cookies['expiration'])
        # use existing cookies unless they're expired
        if cookie_expiration > Time.now
          return cookies
        end
      end
      response = RestClient.get(BASE_URL + "?page=#{@page}", cookies: cookies)
      new_cookies = response.cookies
      cookie_expiration = response.cookie_jar.map(&:expires_at).compact.min
      @storage.save_cookies(COOKIE_SITE, new_cookies, cookie_expiration)
      new_cookies
    end

    def final_page?
      @logger.info @doc.search('.page.next')
      @doc.search('.page.next').empty? || @doc.search('.page.next.disabled').any?
    end

    def clinics
      container = @doc.search('.main-container > div')[1]
      unless container
        return []
      end

      results = container.search('> div.justify-between').map do |group|
        Clinic.new(group, @logger, @storage)
      end.filter do |clinic|
        clinic.valid?
      end

      unless results.any?
        Sentry.capture_message("[VaccinateRI] Couldn't find any clinics!")
      end

      results.filter do |clinic|
        clinic.appointments.positive?
      end.each do |clinic|
      end

      results
    end
  end

  class Clinic < BaseClinic
    TITLE_MATCHER = %r[^(.+) on (\d{2}/\d{2}/\d{4})$].freeze

    attr_accessor :appointments

    def initialize(group, logger, storage)
      super(storage)
      @group = group
      @logger = logger
      @paragraphs = group.search('p')
      @parsed_info = @paragraphs[2..].each_with_object({}) do |p, h|
        match = /^([\w\d\s]+):\s+(.+)$/.match(p.content)
        next unless match

        h[match[1].strip] = match[2].strip
      end
      @appointments = @parsed_info['Appointments Available or Currently Being Booked'].to_i
    end

    def valid?
      @parsed_info.key?('Appointments Available or Currently Being Booked')
    end

    def to_s
      "Clinic: #{title}"
    end

    def title
      @paragraphs[0].content.strip
    end

    def address
      @paragraphs[1].content.strip
    end

    def city
      match = address.match(/^.*, ([\w\d\s]+) (MA|Massachusetts),/i)
      return nil unless match

      match[1]
    end

    def vaccine
      @parsed_info['Vaccinations offered']
    end

    def age_groups
      @parsed_info['Age groups served']
    end

    def additional_info
      @parsed_info['Additional Information']
    end

    def link
      a_tag = @paragraphs.last.search('a')
      return nil unless a_tag.any?

      'https://www.vaccinateri.org' + a_tag[0]['href']
    end

    def name
      match = TITLE_MATCHER.match(title)
      match && match[1].strip
    end

    def date
      match = TITLE_MATCHER.match(title)
      match && match[2]
    end

    def slack_blocks
      {
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: "*#{title}*\n*Address:* #{address}\n*Vaccine:* #{vaccine}\n*Age groups*: #{age_groups}\n*Available appointments:* #{render_slack_appointments}\n*Additional info:* #{additional_info}\n*Link:* #{link}",
        },
      }
    end

    def twitter_text
      txt = "#{appointments} appointments available at #{name}"
      txt += " in #{city}, MA" if city
      txt + " on #{date}. Check eligibility and sign up at #{sign_up_page}"
    end

    def sign_up_page
      addr = 'https://www.vaccinateri.org/clinic/search?'
      addr += "q[venue_search_name_or_venue_name_i_cont]=#{name}&" if name
      URI.parse(addr)
    end
  end
end
