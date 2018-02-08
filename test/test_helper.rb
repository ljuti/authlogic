require "rubygems"
require "minitest/autorun"
require "active_record"
require "active_record/fixtures"
require "timecop"
require "i18n"

I18n.load_path << File.dirname(__FILE__) + '/i18n/lol.yml'

# ActiveRecord::Schema.verbose = false
ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :database => ":memory:")
logger = Logger.new(STDOUT)
logger.level = Logger::FATAL
ActiveRecord::Base.logger = logger

if (ActiveRecord::VERSION::STRING < '4.1')
  ActiveRecord::Base.configurations = true
end

if ActiveSupport.respond_to?(:test_order)
  ActiveSupport.test_order = :sorted
end

ActiveRecord::Base.default_timezone = :local
ActiveRecord::Schema.define(:version => 1) do
  create_table :companies do |t|
    t.datetime  :created_at
    t.datetime  :updated_at
    t.string    :name
    t.boolean   :active
  end

  create_table :projects do |t|
    t.datetime  :created_at
    t.datetime  :updated_at
    t.string    :name
  end

  create_table :projects_users, :id => false do |t|
    t.integer :project_id
    t.integer :user_id
  end

  create_table :users do |t|
    t.datetime  :created_at
    t.datetime  :updated_at
    t.integer   :lock_version, :default => 0
    t.integer   :company_id
    t.string    :login
    t.string    :crypted_password
    t.string    :password_salt
    t.string    :persistence_token
    t.string    :single_access_token
    t.string    :perishable_token
    t.string    :email
    t.string    :first_name
    t.string    :last_name
    t.integer   :login_count, :default => 0, :null => false
    t.integer   :failed_login_count, :default => 0, :null => false
    t.datetime  :last_request_at
    t.datetime  :current_login_at
    t.datetime  :last_login_at
    t.string    :current_login_ip
    t.string    :last_login_ip
    t.boolean   :active, :default => true
    t.boolean   :approved, :default => true
    t.boolean   :confirmed, :default => true
  end

  create_table :employees do |t|
    t.datetime  :created_at
    t.datetime  :updated_at
    t.integer   :company_id
    t.string    :email
    t.string    :crypted_password
    t.string    :password_salt
    t.string    :persistence_token
    t.string    :first_name
    t.string    :last_name
    t.integer   :login_count, :default => 0, :null => false
    t.datetime  :last_request_at
    t.datetime  :current_login_at
    t.datetime  :last_login_at
    t.string    :current_login_ip
    t.string    :last_login_ip
  end

  create_table :affiliates do |t|
    t.datetime  :created_at
    t.datetime  :updated_at
    t.integer   :company_id
    t.string    :username
    t.string    :pw_hash
    t.string    :pw_salt
    t.string    :persistence_token
  end

  create_table :ldapers do |t|
    t.datetime  :created_at
    t.datetime  :updated_at
    t.string    :ldap_login
    t.string    :persistence_token
  end
end

require_relative '../lib/authlogic' unless defined?(Authlogic)
require_relative '../lib/authlogic/test_case'
require_relative 'libs/project'
require_relative 'libs/affiliate'
require_relative 'libs/employee'
require_relative 'libs/employee_session'
require_relative 'libs/ldaper'
require_relative 'libs/user'
require_relative 'libs/user_session'
require_relative 'libs/company'

# Recent change, 2017-10-23: We had used a 54-letter string here. In the default
# encoding, UTF-8, that's 54 bytes, which is clearly incorrect for an algorithm
# with a 256-bit key, but I guess it worked. With the release of ruby 2.4 (and
# thus openssl gem 2.0), it is more strict, and must be exactly 32 bytes.
Authlogic::CryptoProviders::AES256.key = ::OpenSSL::Random.random_bytes(32)

class ActiveSupport::TestCase
  include ActiveRecord::TestFixtures
  self.fixture_path = File.dirname(__FILE__) + "/fixtures"

  # use_transactional_fixtures= is deprecated and will be removed from Rails 5.1
  # (use use_transactional_tests= instead)
  if respond_to?(:use_transactional_tests=)
    self.use_transactional_tests = false
  else
    self.use_transactional_fixtures = false
  end

  self.use_instantiated_fixtures = false
  self.pre_loaded_fixtures = false
  fixtures :all
  setup :activate_authlogic
  setup :config_setup
  teardown :config_teardown
  teardown { Timecop.return } # for tests that need to freeze the time

  private

    # Many of the tests change Authlogic config for the test models. Some tests
    # were not resetting the config after tests, which didn't surface as broken
    # tests until Rails 4.1 was added for testing. This ensures that all the
    # models start tests with their original config.
    def config_setup
      [Project, Affiliate, Employee, EmployeeSession, Ldaper, User, UserSession, Company].each do |model|
        model.class_attribute :original_acts_as_authentic_config unless model.respond_to?(:original_acts_as_authentic_config)
        model.original_acts_as_authentic_config = model.acts_as_authentic_config
      end
    end

    def config_teardown
      [Project, Affiliate, Employee, EmployeeSession, Ldaper, User, UserSession, Company].each do |model|
        model.acts_as_authentic_config = model.original_acts_as_authentic_config
      end
    end

    def password_for(user)
      case user
      when users(:ben)
        "benrocks"
      when users(:zack)
        "zackrocks"
      when users(:aaron)
        "aaronrocks"
      end
    end

    def http_basic_auth_for(user = nil, &block)
      unless user.blank?
        controller.http_user = user.login
        controller.http_password = password_for(user)
      end
      yield
      controller.http_user = controller.http_password = controller.realm = nil
    end

    def set_cookie_for(user)
      controller.cookies["user_credentials"] = { :value => "#{user.persistence_token}::#{user.id}", :expires => nil }
    end

    def unset_cookie
      controller.cookies["user_credentials"] = nil
    end

    def set_params_for(user)
      controller.params["user_credentials"] = user.single_access_token
    end

    def unset_params
      controller.params["user_credentials"] = nil
    end

    def set_request_content_type(type)
      controller.request_content_type = type
    end

    def unset_request_content_type
      controller.request_content_type = nil
    end

    def session_credentials_prefix(scope_record)
      if scope_record.nil?
        ""
      else
        format(
          "%s_%d_",
          scope_record.class.model_name.name.underscore,
          scope_record.id
        )
      end
    end

    # Sets the session variables that `record` (eg. a `User`) would have after
    # logging in.
    #
    # If `record` belongs to an `authenticates_many` association that uses the
    # `scope_cookies` option, then a `scope_record` can be provided.
    def set_session_for(record, scope_record = nil)
      prefix = session_credentials_prefix(scope_record)
      record_class_name = record.class.model_name.name.underscore
      controller.session["#{prefix}#{record_class_name}_credentials"] = record.persistence_token
      controller.session["#{prefix}#{record_class_name}_credentials_id"] = record.id
    end

    def unset_session
      controller.session["user_credentials"] = controller.session["user_credentials_id"] = nil
    end
end
