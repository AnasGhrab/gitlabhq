# Updates project records containing invalid URLs using the AddressableUrlValidator.
# This is optimized assuming the number of invalid records is low, but
# we still need to loop through all the projects with an +import_url+
# so we use batching for the latter.
#
# This migration is non-reversible as we would have to keep the old data.

class FixNoValidatableImportUrl < ActiveRecord::Migration
  include Gitlab::Database::MigrationHelpers
  class SqlBatches

    attr_reader :results, :query

    def initialize(batch_size: 100, query:)
      @offset = 0
      @batch_size = batch_size
      @query = query
      @results = []
    end

    def next?
      @results = ActiveRecord::Base.connection.exec_query(batched_sql)
      @offset += @batch_size
      @results.any?
    end

    private

    def batched_sql
      "#{@query} LIMIT #{@batch_size} OFFSET #{@offset}"
    end
  end

  # AddressableValidator - Snapshot of AddressableUrlValidator
  module AddressableUrlValidatorSnap
    extend self

    def valid_url?(value)
      return false unless value

      valid_uri?(value) && valid_protocol?(value)
    rescue Addressable::URI::InvalidURIError
      false
    end

    def valid_uri?(value)
      Addressable::URI.parse(value).is_a?(Addressable::URI)
    end

    def valid_protocol?(value)
      value =~ /\A#{URI.regexp(%w(http https ssh git))}\z/
    end
  end

  def up
    unless defined?(Addressable::URI::InvalidURIError)
      say('Skipping cleaning up invalid import URLs as class from Addressable is missing')
      return
    end

    say('Cleaning up invalid import URLs... This may take a few minutes if we have a large number of imported projects.')

    invalid_import_url_project_ids.each { |project_id| cleanup_import_url(project_id) }
  end

  def invalid_import_url_project_ids
    ids = []
    batches = SqlBatches.new(query: "SELECT id, import_url FROM projects WHERE import_url IS NOT NULL")

    while batches.next?
      batches.results.each do |result|
        ids << result['id'] unless valid_url?(result['import_url'])
      end
    end

    ids
  end

  def valid_url?(url)
    AddressableUrlValidatorSnap.valid_url?(url)
  end

  def cleanup_import_url(project_id)
    execute("UPDATE projects SET import_url = NULL WHERE id = #{project_id}")
  end
end
