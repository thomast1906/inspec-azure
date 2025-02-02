require 'azure_backend'

# The backend class for the singular static resources.
#
# @author omerdemirok
#
class AzureGenericResource < AzureResourceBase
  name 'azure_generic_resource'
  desc 'Inspec Resource to interrogate any resource type available through Azure Resource Manager'
  example <<-EXAMPLE
    describe azure_generic_resource(resource_group: 'example', name: 'my_resource') do
      its('name') { should eq 'my_resource' }
    end
  EXAMPLE

  def initialize(opts = {}, static_resource = false) # rubocop:disable Style/OptionalBooleanParameter TODO: Fix disabled rubocop issue.
    super(opts)
    @resource_id = ''
    if @opts.key?(:resource_provider)
      validate_resource_provider
    end
    if static_resource
      validate_static_resource
    else
      validate_generic_resource
      return if failed_resource?
    end
    @display_name = if @opts[:display_name].nil?
                      @opts.slice(:resource_group, :resource_provider, :name, :tag_name, :tag_value, :resource_id,
                                  :resource_uri).values.join(' ')
                    else
                      @opts[:display_name]
                    end
    if @opts[:is_uri_a_url]
      query_params = { resource_uri: @opts[:resource_uri] }
    else
      resource_fail('There is not enough input to create an Azure resource ID.') if @resource_id.empty?
      # This is the last check on resource_id before talking to resource manager endpoint to get the detailed information.
      Validators.validate_resource_uri(@resource_id)
      query_params = { resource_uri: @resource_id }
    end
    query_params[:query_parameters] = {}
    # Use the latest api_version unless provided.
    query_params[:query_parameters]['api-version'] = @opts[:api_version] || 'latest'
    %i(is_uri_a_url headers method req_body audience).each do |param|
      query_params[param] = @opts[param] unless @opts[param].nil?
    end
    @opts[:query_parameters]&.each do |k, v|
      query_params[:query_parameters].merge!({ k => v })
    end
    catch_failed_resource_queries do
      @resource_long_desc = get_resource(query_params)
    end
    # If an exception is raised above then the resource is failed.
    # This check should be done every time after using catch_failed_resource_queries
    return if failed_resource?

    # resource_long_desc should be a Hash object
    # &
    # All resources must have a id unless the full URL is provided.
    unless @resource_long_desc.is_a?(Hash) && @resource_long_desc.key?(:id)
      unless @opts[:is_uri_a_url] # rubocop:disable Style/SoleNestedConditional TODO: Fix this.
        resource_fail("Unable to get the detailed information for the resource_id: #{@resource_id}")
      end
    end

    if @opts[:transform_keys].present?
      @resource_long_desc.deep_transform_keys!(&@opts[:transform_keys])
    end

    # Create resource methods with the properties of the resource.
    create_resource_methods(@resource_long_desc)
  end

  def exists?
    !failed_resource?
  end

  def to_s(class_name = nil)
    api_info = "- api_version: #{api_version_used_for_query} #{api_version_used_for_query_state}" if defined?(api_version_used_for_query)
    if class_name.nil?
      "#{AzureGenericResource.name.split('_').map(&:capitalize).join(' ')} #{api_info}: #{@display_name}"
    else
      "#{class_name.name.split('_').map(&:capitalize).join(' ')} #{api_info}: #{@display_name}"
    end
  end

  def resource_group
    return unless exists?
    res_group, _provider, _res_type = Helpers.res_group_provider_type_from_uri(id)
    res_group
  end

  # Track the status of the resource at InSpec Azure resource pack level.
  #
  # @return [TrueClass, FalseClass] Whether the resource is failed or not.
  def failed_resource?
    @failed_resource ||= false
  end

  # Create properties on a resource acquired via additional API call in a static method.
  # @param opts [Hash]
  #   property_name [string] The name of the property.
  #   property_endpoint [string] The URI of the properties.
  #     E.g., '/subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/
  #     Microsoft.Sql/servers/{serverName}/firewallRules'.
  #   api_version [string] The api version of the endpoint (default - latest).
  def additional_resource_properties(opts = {})
    Validators.validate_parameters(resource_name: @__resource_name__,
                                   required: %i(property_name property_endpoint),
                                   allow: %i(api_version filter_free_text add_subscription_id method req_body headers),
                                   opts: opts)
    unless opts[:add_subscription_id].nil?
      opts[:property_endpoint] = validate_resource_uri(
        {
          resource_uri: opts[:property_endpoint],
          add_subscription_id: opts[:add_subscription_id],
        },
      )
    end
    query_params = { resource_uri: opts[:property_endpoint] }
    query_params[:query_parameters] = {}
    unless opts[:filter_free_text].nil?
      query_params[:query_parameters]['$filter'] = opts[:filter_free_text]
    end
    query_params[:query_parameters]['api-version'] = opts[:api_version] || 'latest'

    %i(is_uri_a_url headers method req_body audience).each do |param|
      query_params[param] = opts[param] unless opts[param].nil?
    end
    properties = get_resource(query_params)
    properties = properties[:value] if properties.key?(:value)
    create_resource_methods({ opts[:property_name].to_sym => properties })
    public_send(opts[:property_name].to_sym) if respond_to?(opts[:property_name])
  end

  private

  def validate_static_resource
    required_parameters = %i(resource_group resource_provider name)
    required_parameters += @opts[:required_parameters] if @opts.key?(:required_parameters)
    allowed_parameters = %i(resource_path resource_identifiers resource_id resource_uri add_subscription_id
                            query_parameters is_uri_a_url audience transform_keys)
    allowed_parameters += @opts[:allowed_parameters] if @opts.key?(:allowed_parameters)

    if @opts.key?(:resource_id)
      validate_parameters(required: %i(resource_provider resource_id), allow: allowed_parameters + required_parameters)
      @resource_id = @opts[:resource_id]
      return
    end

    if @opts[:resource_identifiers]
      raise ArgumentError, '`:resource_identifiers` should be a list.' unless @opts[:resource_identifiers].is_a?(Array)
      # The `name` parameter should have been required in the static resource.
      # Since it is a mandatory field, it is better to make sure that it is in the required list before validations.
      @opts[:resource_identifiers] << :name unless @opts[:resource_identifiers].include?(:name)
      provided = Validators.validate_params_only_one_of(@__resource_name__, @opts[:resource_identifiers], @opts)
      # Remove resource identifiers other than `:name`.
      unless provided == :name
        @opts[:name] = @opts[provided]
        @opts.delete(provided)
      end
    end

    if @opts.key?(:resource_uri)
      return if @opts[:is_uri_a_url]
      validate_resource_uri
      validate_parameters(required: %i(resource_uri name add_subscription_id),
                          allow: allowed_parameters + required_parameters)
      @resource_id = [@opts[:resource_uri], @opts[:name]].join('/').gsub('//', '/')
      return
    end

    validate_parameters(required: required_parameters, allow: allowed_parameters)
    @resource_id = construct_resource_id
  end

  def validate_generic_resource
    # Get/create or acquire the resource_id.
    # The resource_id is a MUST to get the detailed resource information.
    #
    # Use the provided resource_id
    if @opts.key?(:resource_uri)
      validate_parameters(required: %i(resource_uri add_subscription_id name), allow: %i(query_parameters is_uri_a_url audience headers transform_keys))
      validate_resource_uri
      @resource_id = [@opts[:resource_uri], @opts[:name]].join('/').gsub('//', '/')
    elsif @opts.key?(:resource_id)
      validate_parameters(required: %i(resource_id), allow: %i(transform_keys))
      @resource_id = @opts[:resource_id]
    else
      validate_parameters(require_any_of: %i(resource_group resource_path name tag_name tag_value resource_id
                                             resource_provider), allow: %i(transform_keys))
      # resource_group + resource_provider + name
      if %i(resource_group resource_provider name).all? { |param| @opts.keys.include?(param) }
        @resource_id = construct_resource_id
      else
        # Query the resource management endpoint to get the resource_id with the provided parameters.
        # Either one of the following sets can be provided for a valid short description query (to get the resource_id).
        # resource_group + name
        # name
        # tag_name + tag_value
        filter = @opts.slice(:resource_group, :name, :resource_provider, :tag_name, :tag_value, :location)
        catch_failed_resource_queries do
          # This filter will be used to query the Rest API.
          # At this point the resource_provider should be identical to resource_type which is an allowed query parameter.
          filter[:resource_type] = filter[:resource_provider] unless filter[:resource_provider].nil?
          filter.delete(:resource_provider)
          @resources = resource_short(filter)
          # If an exception is raised above then the resource is failed.
          # This check should be done every time after using catch_failed_resource_queries
          #
          return if failed_resource?

          # Validate short description whether:
          # There is a resource description? (0: it should_not exist, nil: fail resource)
          # There are multiple resource description? (fail resource for singular resource)
          #
          validated = validate_short_desc(@resources, filter, true)
          # If resource description is not in expected format, resource will be failed here.
          return unless validated

          # For a singular resource there must be one and only resource description with a resource_id.
          @resource_id = @resources.first[:id]
        end
      end
    end
  end
end
