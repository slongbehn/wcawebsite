# frozen_string_literal: true

class ServerStatusController < ApplicationController
  def index
    @locale_stats = ApplicationController.locale_counts.sort_by { |_locale, count| count }.reverse

    @checks = checks
    @everything_good = @checks.all?(&:passing?)
    render status: :service_unavailable unless @everything_good
  end

  def checks
    [
      JobsCheck.new,
      RegulationsCheck.new,
      MysqlSettingsCheck.new,
    ]
  end
end

class StatusCheck
  def passing?
    status == :success
  end

  def status_description
    # Computing the status may be expensive, in which case we don't want to do it
    # multiple times, so we memoize the result here.
    @status_description ||= self._status_description
  end

  def status
    status_description[0]
  end

  def description
    status_description[1]
  end
end

class JobsCheck < StatusCheck
  MINUTES_IN_WHICH_A_JOB_SHOULD_HAVE_STARTED_RUNNING = 5
  include ActionView::Helpers::DateHelper

  def label
    "Jobs"
  end

  protected def _status_description
    jobs_that_should_have_run_by_now = CronjobStatistic.where(recently_rejected: 0, run_start: nil)
                                                       .where(enqueued_at: ...MINUTES_IN_WHICH_A_JOB_SHOULD_HAVE_STARTED_RUNNING.minutes.ago)

    oldest_job_that_should_have_run_by_now = jobs_that_should_have_run_by_now.order(:enqueued_at).first

    if oldest_job_that_should_have_run_by_now.nil?
      [:success, nil]
    else
      [
        :danger,
        %(
          Uh oh!
          Job #{oldest_job_that_should_have_run_by_now.id} was enqueued
          #{time_ago_in_words oldest_job_that_should_have_run_by_now.enqueued_at}
          ago and still has not run.
          #{jobs_that_should_have_run_by_now.count}
          #{'job'.pluralize(jobs_that_should_have_run_by_now.count)}
          #{'is'.pluralize(jobs_that_should_have_run_by_now.count)}
          waiting to run.
        ).squish,
      ]
    end
  end
end

class RegulationsCheck < StatusCheck
  def label
    "Regulations"
  end

  protected def _status_description
    if Regulation.regulations_load_error.nil?
      [:success, nil]
    else
      [:danger, "Error while loading regulations: #{Regulation.regulations_load_error} from #{Regulation.regulations_load_error.class}"]
    end
  end
end

class MysqlSettingsCheck < StatusCheck
  EXPECTED_MYSQL_SETTINGS = {
    "@@innodb_ft_min_token_size" => 2,
    "@@ft_min_word_len" => 2,
    "@@character_set_server" => "utf8mb4",
  }.freeze

  def label
    "MySQL"
  end

  protected def _status_description
    actual_mysql_settings = ActiveRecord::Base.connection.select_one("SELECT #{EXPECTED_MYSQL_SETTINGS.keys.join(', ')};")
    mysql_settings_good = true
    description = ""
    EXPECTED_MYSQL_SETTINGS.each do |setting, expected_value|
      actual_value = actual_mysql_settings[setting]
      if actual_value != expected_value
        mysql_settings_good = false
        description += "#{setting}: expected #{expected_value} != actual #{actual_value}\n"
      end
    end

    if mysql_settings_good
      [:success, nil]
    else
      [:danger, description]
    end
  end
end
