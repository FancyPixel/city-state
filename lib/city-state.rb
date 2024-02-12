require 'uri'
require "city-state/version"
require 'yaml'

module CS
  # CS constants
  FILES_FOLDER = File.expand_path('../db', __FILE__)
  MAXMIND_DB_FN = File.join(FILES_FOLDER, "GeoLite2-City-Locations-en.csv")
  COUNTRIES_FN = File.join(FILES_FOLDER, "countries.yml")
  DEFAULT_CITIES_LOOKUP_FN    = 'db/cities-lookup.yml'
  DEFAULT_STATES_LOOKUP_FN    = 'db/states-lookup.yml'
  DEFAULT_PROVINCES_LOOKUP_FN    = 'db/provinces-lookup.yml'
  DEFAULT_COUNTRIES_LOOKUP_FN = 'db/countries-lookup.yml'
  DEFAULT_PROV_STATE_LOOKUP_FN = 'db/prov_state-lookup.yml'
  ITALIAN_CITIES_FN = File.join(FILES_FOLDER, "Elenco-comuni-italiani.csv")

  @countries, @states, @cities, @cities_prov, @provinces, @prov_state = [{}, {}, {}, {}, {}, {}]
  @current_country = nil # :US, :BR, :GB, :JP, ...
  @maxmind_zip_url = nil
  @license_key = nil

  # lookup tables for state/cities renaming
  @cities_lookup_fn = nil
  @cities_lookup = nil
  @states_lookup_fn = nil
  @states_lookup = nil
  @provinces_lookup_fn = nil
  @provinces_lookup = nil
  @countries_lookup_fn = nil
  @countries_lookup = nil
  @prov_state_lookup = nil

  def self.set_maxmind_zip_url(maxmind_zip_url)
    @maxmind_zip_url = maxmind_zip_url
  end

  def self.set_license_key(license_key)
    url = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City-CSV&license_key=#{license_key}&suffix=zip"
    @license_key = license_key
    self.set_maxmind_zip_url(url)
  end

  def self.update_maxmind
    require "open-uri"
    require "zip"

    # get zipped file
    return false if !@maxmind_zip_url
    f_zipped = URI.open(@maxmind_zip_url)

    # unzip file:
    # recursively searches for "GeoLite2-City-Locations-en"
    Zip::File.open(f_zipped) do |zip_file|
      zip_file.each do |entry|
        if self.present?(entry.name["GeoLite2-City-Locations-en"])
          fn = entry.name.split("/").last
          entry.extract(File.join(FILES_FOLDER, fn)) { true } # { true } is to overwrite
          break
        end
      end
    end
    true
  end

  def self.update
    self.update_maxmind # update via internet
    Dir[File.join(FILES_FOLDER, "states.*")].each do |state_fn|
      self.install(state_fn.split(".").last.upcase.to_sym) # reinstall country
    end
    @countries, @states, @cities = [{}, {}, {}] # invalidades cache
    File.delete COUNTRIES_FN # force countries.yml to be generated at next call of CS.countries
    true
  end

  # constants: CVS position
  ID = 0
  COUNTRY = 4
  COUNTRY_LONG = 5
  STATE = 6
  STATE_LONG = 7
  PROV = 8
  PROV_LONG = 9
  CITY = 10

  ITALIAN_CITY = 5
  ITALIAN_PROV = 14
  CITY_CODE = 19

  def self.install(country)
    # get CSV if doesn't exists
    update_maxmind unless File.exist? MAXMIND_DB_FN

    # normalize "country"
    country = country.to_s.upcase

    # some state codes are empty: we'll use "states-replace" in these cases
    states_replace_fn = File.join(FILES_FOLDER, "states-replace.yml")
    states_replace = self.symbolize_keys(YAML::load_file(states_replace_fn))
    states_replace = states_replace[country.to_sym] || {} # we need just this country
    states_replace_inv = states_replace.invert # invert key with value, to ease the search

    # read CSV line by line
    cities = {}
    provinces = {}
    cities_prov = {}
    prov_state = {}
    states = {}
    File.foreach(MAXMIND_DB_FN) do |line|
      rec = line.split(",")
      next if rec[COUNTRY] != country
      next if (self.blank?(rec[STATE]) && self.blank?(rec[STATE_LONG])) || self.blank?(rec[CITY])

      # some state codes are empty: we'll use "states-replace" in these cases
      rec[STATE] = states_replace_inv[rec[STATE_LONG]] if self.blank?(rec[STATE])
      rec[STATE] = rec[STATE_LONG] if self.blank?(rec[STATE]) # there's no correspondent in states-replace: we'll use the long name as code

      # some long names are empty: we'll use "states-replace" to get the code
      rec[STATE_LONG] = states_replace[rec[STATE]] if self.blank?(rec[STATE_LONG])

      # normalize
      rec[STATE] = rec[STATE].to_sym
      rec[CITY].gsub!(/\"/, "") # sometimes names come with a "\" char
      rec[STATE_LONG].gsub!(/\"/, "") # sometimes names come with a "\" char

      # normalize prov
      rec[PROV] = rec[PROV].to_sym
      rec[PROV_LONG].gsub!(/\"/, "") # sometimes names come with a "\" char

      cities_prov.merge!({rec[PROV] => {}}) if !provinces.has_key?(rec[PROV])
      # cities_prov[rec[PROV]] << rec[CITY]

      if ! provinces.has_key?(rec[PROV])
        province = {rec[PROV] => rec[PROV_LONG]}
        provinces.merge!(province)
      end

      # provinces list: {45: [:"FE", :"BO", ... ]} with dups
      prov_state.merge!({rec[STATE] => []}) if ! states.has_key?(rec[STATE])
      prov_state[rec[STATE]] << rec[PROV]

      # cities list: {TX: ["Texas City", "Another", "Another 2"]}
      cities.merge!({rec[STATE] => []}) if ! states.has_key?(rec[STATE])
      cities[rec[STATE]] << rec[CITY]

      # states list: {TX: "Texas", CA: "California"}
      if ! states.has_key?(rec[STATE])
        state = {rec[STATE] => rec[STATE_LONG]}
        states.merge!(state)
      end
    end

    if country == "IT"
      cities_prov[:SU]={}
      File.foreach(ITALIAN_CITIES_FN).with_index do |line, index|
        next if index == 0
        rec = line.split(";")
        rec[ITALIAN_PROV] = rec[ITALIAN_PROV].to_sym
        rec[CITY_CODE] = rec[CITY_CODE].to_sym
        # puts cities_prov[rec[ITALIAN_PROV]]
        cities_prov[rec[ITALIAN_PROV]][rec[CITY_CODE]] = rec[ITALIAN_CITY]
      end

      # sort provinces and cities_prov
      cities_prov = Hash[cities_prov.sort]
      provinces = Hash[provinces.sort]
      prov_state = Hash[prov_state.sort]
      unless country == "IT"
        cities_prov.each { |k, v| cities_prov[k].sort! }
      else
        cities_prov.each { |k, v| cities_prov[k] = cities_prov[k].invert.sort.to_h.invert }
        prov_state.each { |k, v| prov_state[k] = prov_state[k].uniq!.sort }
      end

      provices_fn = File.join(FILES_FOLDER, "provinces.#{country.downcase}")
      cities_prov_fn = File.join(FILES_FOLDER, "cities_prov.#{country.downcase}")
      prov_state_fn = File.join(FILES_FOLDER, "prov_state.#{country.downcase}")
      File.open(provices_fn, "w") { |f| f.write provinces.to_yaml }
      File.open(cities_prov_fn, "w") { |f| f.write cities_prov.to_yaml }
      File.open(prov_state_fn, "w") { |f| f.write prov_state.to_yaml }
      File.chmod(0666, provices_fn, cities_prov_fn, prov_state_fn) # force permissions to rw_rw_rw_ (issue #3)
    end

    # sort
    cities = Hash[cities.sort]
    states = Hash[states.sort]
    cities.each { |k, v| cities[k].sort! }

    # save to states.us and cities.us
    states_fn = File.join(FILES_FOLDER, "states.#{country.downcase}")
    cities_fn = File.join(FILES_FOLDER, "cities.#{country.downcase}")
    File.open(states_fn, "w") { |f| f.write states.to_yaml }
    File.open(cities_fn, "w") { |f| f.write cities.to_yaml }
    File.chmod(0666, states_fn, cities_fn) # force permissions to rw_rw_rw_ (issue #3)
    true
  end

  def self.current_country
    return @current_country if self.present?(@current_country)

    # we don't have used this method yet: discover by the file extension
    fn = Dir[File.join(FILES_FOLDER, "cities.*")].last
    @current_country = self.blank?(fn) ? nil : fn.split(".").last

    # there's no files: we'll install and use :US
    if self.blank?(@current_country)
      @current_country = :US
      self.install(@current_country)

    # we find a file: normalize the extension to something like :US
    else
      @current_country = @current_country.to_s.upcase.to_sym
    end

    @current_country
  end

  def self.current_country=(country)
    @current_country = country.to_s.upcase.to_sym
  end

  def self.cities(state, country = nil)
    self.current_country = country if self.present?(country) # set as current_country
    country = self.current_country
    state = state.to_s.upcase.to_sym

    # load the country file
    if self.blank?(@cities[country])
      cities_fn = File.join(FILES_FOLDER, "cities.#{country.to_s.downcase}")
      self.install(country) unless File.exist?(cities_fn)
      @cities[country] = self.symbolize_keys(YAML::load_file(cities_fn))

      # Remove duplicated cities
      @cities[country].each do |key, value|
        @cities[country][key] = value.uniq || []
      end

      # Process lookup table
      lookup = get_cities_lookup(country)
      unless lookup.nil?
        lookup.each do |state, replacements|
          replacements.each do |old_value, new_value|
            if new_value.nil? || self.blank?(new_value)
              @cities[country][state].delete(old_value)
            else
              index = @cities[country][state].index(old_value)
              if index.nil?
                @cities[country][state] << new_value
              else
                @cities[country][state][index] = new_value
              end
            end
          end
          @cities[country][state] = @cities[country][state].sort # sort it alphabetically
        end
      end
    end

    # Return list
    @cities[country][state]
  end

  def self.cities_prov(province, country = nil)
    self.current_country = country if country.present? # set as current_country
    country = self.current_country

    # load the country file
    if @cities_prov[country].blank?
      cities_prov_fn = File.join(FILES_FOLDER, "cities_prov.#{country.to_s.downcase}")
      self.install(country) if ! File.exist? cities_prov_fn
      @cities_prov[country] = YAML::load_file(cities_prov_fn).symbolize_keys rescue {}
    end

    @cities_prov[country][province.to_s.upcase.to_sym] || {}
  end

  def self.set_cities_lookup_file(filename)
    @cities_lookup_fn = filename
    @cities_lookup    = nil
  end

  def self.set_states_lookup_file(filename)
    @states_lookup_fn = filename
    @states_lookup    = nil
  end

  def self.set_countries_lookup_file(filename)
    @countries_lookup_fn = filename
    @countries_lookup    = nil
  end

  def self.get_cities_lookup(country)
    # lookup file not loaded
    if @cities_lookup.nil?
      @cities_lookup_fn  = DEFAULT_CITIES_LOOKUP_FN if @cities_lookup_fn.nil?
      @cities_lookup_fn  = File.expand_path(@cities_lookup_fn)
      return nil if ! File.exist?(@cities_lookup_fn)
      @cities_lookup = self.symbolize_keys(YAML::load_file(@cities_lookup_fn)) # force countries to be symbols
      @cities_lookup.each { |key, value| @cities_lookup[key] = self.symbolize_keys(value) } # force states to be symbols
    end

    return nil unless @cities_lookup.key?(country)
    @cities_lookup[country]
  end

  def self.get_prov_state_lookup(state)
    # lookup file not loaded
    if @prov_state_lookup.nil?
      @prov_state_lookup_fn  = DEFAULT_PROV_STATE_LOOKUP_FN if @prov_state_lookup_fn.nil?
      @prov_state_lookup_fn  = File.expand_path(@prov_state_lookup_fn)
      return nil if ! File.exist?(@prov_state_lookup_fn)
      @prov_state_lookup = self.symbolize_keys(YAML::load_file(@prov_state_lookup_fn)) # force countries to be symbols
      @prov_state_lookup.each { |key, value| @prov_state_lookup[key] = self.symbolize_keys(value) } # force states to be symbols
    end

    return nil if ! @prov_state_lookup.key?(state)
    @prov_state_lookup[state]
  end

  def self.get_states_lookup(country)
    # lookup file not loaded
    if @states_lookup.nil?
      @states_lookup_fn  = DEFAULT_STATES_LOOKUP_FN if @states_lookup_fn.nil?
      @states_lookup_fn  = File.expand_path(@states_lookup_fn)
      return nil if ! File.exist?(@states_lookup_fn)
      @states_lookup = self.symbolize_keys(YAML::load_file(@states_lookup_fn)) # force countries to be symbols
      @states_lookup.each { |key, value| @states_lookup[key] = self.symbolize_keys(value) } # force states to be symbols
    end

    return nil if ! @states_lookup.key?(country)
    @states_lookup[country]
  end

  def self.get_provinces_lookup(country)
    # lookup file not loaded
    if @provinces_lookup.nil?
      @provinces_lookup_fn  = DEFAULT_PROVINCES_LOOKUP_FN if @provinces_lookup_fn.nil?
      @provinces_lookup_fn  = File.expand_path(@provinces_lookup_fn)
      return nil if ! File.exist?(@provinces_lookup_fn)
      @provinces_lookup = self.symbolize_keys(YAML::load_file(@provinces_lookup_fn)) # force countries to be symbols
      @provinces_lookup.each { |key, value| @provinces_lookup[key] = self.symbolize_keys(value) } # force provinces to be symbols
    end

    return nil if ! @provinces_lookup.key?(country)
    @provinces_lookup[country]
  end

  def self.get_countries_lookup
    # lookup file not loaded
    if @countries_lookup.nil?
      @countries_lookup_fn  = DEFAULT_COUNTRIES_LOOKUP_FN if @countries_lookup_fn.nil?
      @countries_lookup_fn  = File.expand_path(@countries_lookup_fn)
      return nil if ! File.exist?(@countries_lookup_fn)
      @countries_lookup = self.symbolize_keys(YAML::load_file(@countries_lookup_fn)) # force countries to be symbols
    end

    @countries_lookup
  end

  def self.prov_state(state, country)
    # Bugfix: https://github.com/loureirorg/city-state/issues/24
    return {} if (country.nil? || country != "IT".to_sym) 

    # Set it as current_country
    self.current_country = country # set as current_country
    country = self.current_country # normalized

    # Load the country file
    if self.blank?(@prov_state[state])
      prov_state_fn = File.join(FILES_FOLDER, "prov_state.#{country.to_s.downcase}")
      self.install(country) if ! File.exist? prov_state_fn
      @prov_state = self.symbolize_keys(YAML::load_file(prov_state_fn))

      # Process lookup table
      lookup = get_prov_state_lookup(state)
      if ! lookup.nil?
        lookup.each do |key, value|
          if value.nil? || self.blank?(value)
            @prov_state[state].delete(key)
          else
            @prov_state[state][key] = value
          end
        end
        @prov_state[state] = @prov_state[state].sort.to_h # sort it alphabetically
      end
    end

    # Return list
    @prov_state[state] || {}
  end

  def self.provinces(country)
    return {} if country.nil?

    self.current_country = country # set as current_country
    country = self.current_country # normalized

    if self.blank?(@provinces[country])
      provinces_fn = File.join(FILES_FOLDER, "provinces.#{country.to_s.downcase}")
      self.install(country) if ! File.exist? provinces_fn
      @provinces[country] = self.symbolize_keys(YAML::load_file(provinces_fn)) rescue {}

      # Process lookup table
      lookup = get_provinces_lookup(country)
      if ! lookup.nil?
        lookup.each do |key, value|
          if value.nil? || self.blank?(value)
            @provinces[country].delete(key)
          else
            @provinces[country][key] = value
          end
        end
        @provinces[country] = @provinces[country].sort.to_h # sort it alphabetically
      end
    end

    @provinces[country] || {}
  end

  def self.states(country)
    # Bugfix: https://github.com/loureirorg/city-state/issues/24
    return {} if country.nil?

    # Set it as current_country
    self.current_country = country # set as current_country
    country = self.current_country # normalized

    # Load the country file
    if self.blank?(@states[country])
      states_fn = File.join(FILES_FOLDER, "states.#{country.to_s.downcase}")
      self.install(country) if ! File.exist? states_fn
      @states[country] = self.symbolize_keys(YAML::load_file(states_fn))

      # Process lookup table
      lookup = get_states_lookup(country)
      if ! lookup.nil?
        lookup.each do |key, value|
          if value.nil? || self.blank?(value)
            @states[country].delete(key)
          else
            @states[country][key] = value
          end
        end
        @states[country] = @states[country].sort.to_h # sort it alphabetically
      end
    end

    # Return list
    @states[country] || {}
  end

  # list of all countries of the world (countries.yml)
  def self.countries
    if ! File.exist? COUNTRIES_FN
      # countries.yml doesn't exists, extract from MAXMIND_DB
      update_maxmind unless File.exist? MAXMIND_DB_FN

      # reads CSV line by line
      File.foreach(MAXMIND_DB_FN) do |line|
        rec = line.split(",")
        next if self.blank?(rec[COUNTRY]) || self.blank?(rec[COUNTRY_LONG]) # jump empty records
        country = rec[COUNTRY].to_s.upcase.to_sym # normalize to something like :US, :BR
        if self.blank?(@countries[country])
          long = rec[COUNTRY_LONG].gsub(/\"/, "") # sometimes names come with a "\" char
          @countries[country] = long
        end
      end

      # sort and save to "countries.yml"
      @countries = Hash[@countries.sort]
      File.open(COUNTRIES_FN, "w") { |f| f.write @countries.to_yaml }
      File.chmod(0666, COUNTRIES_FN) # force permissions to rw_rw_rw_ (issue #3)
    else
      # countries.yml exists, just read it
      @countries = self.symbolize_keys(YAML::load_file(COUNTRIES_FN))
    end

    # Applies `countries-lookup.yml` if exists
    lookup = self.get_countries_lookup()
    if ! lookup.nil?
      lookup.each do |key, value|
        if value.nil? || self.blank?(value)
          @countries.delete(key)
        else
          @countries[key] = value
        end
      end
      @countries = @countries.sort.to_h # sort it alphabetically
    end

    # Return countries list
    @countries
  end

  # get is a method to simplify the use of city-state
  # get = countries, get(country) = states(country), get(country, state) = cities(state, country)
  def self.get(country = nil, state = nil)
    return self.countries if country.nil?
    return self.states(country) if state.nil?
    return self.cities(state, country)
  end

  # Emulates Rails' `blank?` method
  def self.blank?(obj)
    obj.respond_to?(:empty?) ? !!obj.empty? : !obj
  end

  # Emulates Rails' `present?` method
  def self.present?(obj)
    !self.blank?(obj)
  end

  # Emulates Rails' `symbolize_keys` method
  def self.symbolize_keys(obj)
    obj.transform_keys { |key| key.to_sym rescue key }
  end
end
