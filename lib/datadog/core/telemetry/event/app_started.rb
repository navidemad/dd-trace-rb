# frozen_string_literal: true

require_relative 'base'

module Datadog
  module Core
    module Telemetry
      module Event
        # Telemetry class for the 'app-started' event
        class AppStarted < Base
          def initialize(components:)
            # To not hold a reference to the component tree, generate
            # the event payload here in the constructor.
            #
            # Important: do not store data that contains (or is derived from)
            # the runtime_id or sequence numbers.
            # This event is reused when a process forks, but in the
            # child process the runtime_id would be different and sequence
            # number is reset.
            @configuration = configuration(components.settings, components.agent_settings)
            @install_signature = install_signature(components.settings)
            @products = products(components)
          end

          def type
            'app-started'
          end

          def payload
            {
              products: @products,
              configuration: @configuration,
              install_signature: @install_signature,
              # DEV: Not implemented yet
              # error: error, # Start-up errors
            }
          end

          # Whether the event is actually the app-started event.
          # For the app-started event we follow up by sending
          # app-dependencies-loaded, if the event is
          # app-client-configuration-change we don't send
          # app-dependencies-loaded.
          def app_started?
            true
          end

          private

          def products(components)
            # @type var products: telemetry_products
            products = {
              appsec: {
                # TODO take appsec status out of component tree?
                enabled: components.settings.appsec.enabled,
              },
              profiler: {
                enabled: !!components.profiler&.enabled?,
              },
              dynamic_instrumentation: {
                enabled: !!components.dynamic_instrumentation,
              }
            }

            if (unsupported_reason = Datadog::Profiling.unsupported_reason)
              products[:profiler][:error] = {
                code: 1, # Error code. 0 if no error.
                message: unsupported_reason,
              }
            end

            products
          end

          def configuration(settings, agent_settings)
            # Special values that are not tied to a configuration option
            list = [
              conf_value(
                'DD_GIT_REPOSITORY_URL',
                Core::Environment::Git.git_repository_url,
                (Core::Environment::Git.git_repository_url ? Configuration::Option::Precedence::ENVIRONMENT : Configuration::Option::Precedence::DEFAULT)
              ),
              conf_value(
                'DD_GIT_COMMIT_SHA',
                Core::Environment::Git.git_commit_sha,
                (Core::Environment::Git.git_commit_sha ? Configuration::Option::Precedence::ENVIRONMENT : Configuration::Option::Precedence::DEFAULT)
              ),

              # Mix of env var, programmatic and default config, so we use unknown
              conf_value('DD_AGENT_TRANSPORT', agent_transport(agent_settings), Configuration::Option::Precedence::UNKNOWN), # rubocop:disable CustomCops/EnvStringValidationCop
            ]

            # Set by the customer application (eg. `require 'datadog/auto_instrument'`)
            auto_instrument_enabled = !defined?(Datadog::AutoInstrument::LOADED).nil?
            list << conf_value(
              'tracing.auto_instrument.enabled',
              auto_instrument_enabled,
              auto_instrument_enabled ? Configuration::Option::Precedence::PROGRAMMATIC : Configuration::Option::Precedence::DEFAULT
            )
            opentelemetry_enabled = !defined?(Datadog::OpenTelemetry::LOADED).nil?
            list << conf_value(
              'tracing.opentelemetry.enabled',
              opentelemetry_enabled,
              opentelemetry_enabled ? Configuration::Option::Precedence::PROGRAMMATIC : Configuration::Option::Precedence::DEFAULT
            )

            # Track ssi configurations
            instrumentation_source = if Datadog.const_defined?(:SingleStepInstrument, false) &&
                Datadog::SingleStepInstrument.const_defined?(:LOADED, false) &&
                Datadog::SingleStepInstrument::LOADED
              'ssi'
            else
              'manual'
            end

            list.push(
              conf_value(
                'instrumentation_source',
                instrumentation_source,
                (instrumentation_source == 'ssi') ? Configuration::Option::Precedence::PROGRAMMATIC : Configuration::Option::Precedence::DEFAULT
              ),
              conf_value(
                'DD_INJECT_FORCE',
                Core::Environment::VariableHelpers.env_to_bool('DD_INJECT_FORCE', false),
                (DATADOG_ENV.key?('DD_INJECT_FORCE') ? Configuration::Option::Precedence::ENVIRONMENT : Configuration::Option::Precedence::DEFAULT)
              ),
              conf_value(
                'DD_INJECTION_ENABLED',
                DATADOG_ENV['DD_INJECTION_ENABLED'] || '',
                (DATADOG_ENV.key?('DD_INJECTION_ENABLED') ? Configuration::Option::Precedence::ENVIRONMENT : Configuration::Option::Precedence::DEFAULT)
              ),
            )

            configuration_options(settings).each do |option|
              list.push(*payload_entries_for_option(option))
            end

            integration_configuration_entries(settings.tracing).each do |entry|
              list << entry
            end

            # We still want to report nil default and programmatic values as they are valid values
            list.reject! { |entry| entry[:origin] != 'default' && entry[:origin] != 'code' && entry[:value].nil? }
            list
          end

          def agent_transport(agent_settings)
            adapter = agent_settings.adapter
            if adapter == Datadog::Core::Transport::Ext::UnixSocket::ADAPTER
              'UDS'
            else
              'TCP'
            end
          end

          # `origin`: Source of the configuration. One of :
          # - 1: `default`: set when the user has not set any configuration for the key (defaults to a value)
          # - 2:`local_stable_config`: configuration set via a user-managed file
          # - 3:`env_var`: configurations that are set through environment variables
          # - 4:`fleet_stable_config`: configuration is set via the fleet automation Datadog UI
          # - 5:`code`: configurations that are set through the customer application
          # - 6:`remote_config`: values that are set using remote config
          # - 7:`unknown`: set for cases where it is difficult/not possible to determine the source of a config.
          def conf_value(name, value, precedence)
            # @type var result: Configuration::Option::telemetry_configuration
            result = {
              name: name,
              value: value,
              origin: precedence.origin,
              seq_id: precedence.numeric + 1,
            }
            if precedence.origin == 'fleet_stable_config'
              fleet_id = Core::Configuration::StableConfig.configuration.dig(:fleet, :id)
              result[:config_id] = fleet_id if fleet_id
            elsif precedence.origin == 'local_stable_config'
              local_id = Core::Configuration::StableConfig.configuration.dig(:local, :id)
              result[:config_id] = local_id if local_id
            end
            result
          end

          def to_value(value)
            case value
            when Integer, String, true, false, nil
              value
            when Float
              value.to_s
            when Hash
              value.map { |key, nested_value| "#{key}:#{nested_value}" }.join(',')
            when Array
              value.join(',')
            when Range
              "#{value.begin}-#{value.end}"
            when Datadog::Tracing::Contrib::StatusRangeMatcher
              value.ranges.map { |range| range.is_a?(Range) ? "#{range.begin}-#{range.end}" : range.to_s }.join(',')
            when Proc, Method
              value.class.to_s
            else
              if value.is_a?(Module)
                value.name.to_s
              elsif custom_to_s?(value)
                value.to_s
              else
                value.class.to_s
              end
            end
          end

          def install_signature(settings)
            {
              install_id: settings.dig('telemetry', 'install_id'),
              install_type: settings.dig('telemetry', 'install_type'),
              install_time: settings.dig('telemetry', 'install_time'),
            }
          end

          def configuration_options(settings)
            settings.class.options.each_key.each_with_object([]) do |name, options|
              option = settings.send(:resolve_option, name)
              value = option.get

              if settings_object?(value)
                options.concat(configuration_options(value))
              else
                options << option
              end
            end
          end

          def integration_configuration_entries(tracing_settings)
            return [] unless tracing_settings.respond_to?(:instrumented_integrations)

            tracing_settings.instrumented_integrations.each_with_object([]) do |(integration_name, integration), entries|
              integration.configurations.each do |matcher, configuration|
                configuration_options(configuration).each do |option|
                  entries.push(
                    *payload_entries_for_option(
                      option,
                      override_name: integration_telemetry_name(integration_name, option, matcher)
                    )
                  )
                end
              end
            end
          end

          def payload_entries_for_option(option, override_name: nil)
            case option.definition.name.to_s
            when 'tracing.writer_options'
              option.telemetry_payload(format_value: false).each_with_object([]) do |source, entries|
                writer_options = source[:value] || {}

                # Steep: **source causes the ::Datadog::Core::Telemetry::Event::telemetry_configuration Record
                # to become a Hash. We can assign it to a value and add an annotation to type it to the correct record.
                # However, overwriting `name` and `value` will cause a FalseAssertion diagnostic.
                entries << {
                  **source,
                  name: 'tracing.writer_options.buffer_size',
                  value: to_value(writer_options[:buffer_size])
                } # steep:ignore ArgumentTypeMismatch
                entries << {
                  **source,
                  name: 'tracing.writer_options.flush_interval',
                  value: to_value(writer_options[:flush_interval])
                } # steep:ignore ArgumentTypeMismatch
              end
            when 'opentelemetry.exporter.headers', 'opentelemetry.metrics.headers'
              option.telemetry_payload(format_value: false).map do |source|
                telemetry_payload_entry(
                  source,
                  name: override_name || source[:name],
                  value: source[:value]&.map { |key, value| "#{key}=#{value}" }&.join(',')
                )
              end
            when 'logger.instance'
              return [] if option.get.nil?

              option.telemetry_payload(format_value: false).map do |source|
                telemetry_payload_entry(
                  source,
                  name: override_name || source[:name],
                  value: source[:value]&.class&.to_s
                )
              end
            else
              formatted_telemetry_payload(option, override_name: override_name)
            end
          end

          def formatted_telemetry_payload(option, override_name: nil)
            option.telemetry_payload(format_value: false).map do |source|
              telemetry_payload_entry(
                source,
                name: override_name || source[:name],
                value: to_value(source[:value])
              )
            end
          end

          def telemetry_payload_entry(source, name:, value:)
            # @type var result: Configuration::Option::telemetry_configuration
            result = {
              name: name,
              value: value,
              origin: source[:origin],
              seq_id: source[:seq_id],
            }
            result[:config_id] = source[:config_id] if source[:config_id]
            result
          end

          def integration_telemetry_name(integration_name, option, matcher)
            return option.definition.env if matcher == :default && option.definition.env

            name = "tracing.#{integration_name}"
            name = "#{name}.#{sanitize_matcher_name(matcher)}" unless matcher == :default
            "#{name}.#{option.definition.name}"
          end

          def sanitize_matcher_name(matcher)
            matcher.to_s.gsub(/[^a-zA-Z0-9_.-]/, '_')
          end

          def custom_to_s?(value)
            value.class.instance_method(:to_s).owner != Kernel
          rescue NameError
            false
          end

          def settings_object?(value)
            value.class.respond_to?(:options) &&
              value.respond_to?(:get_option) &&
              value.respond_to?(:option_defined?)
          end
        end
      end
    end
  end
end
