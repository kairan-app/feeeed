# frozen_string_literal: true

class GraphqlController < ActionController::API
  def execute
    user = authenticate_from_bearer
    variables = prepare_variables(params[:variables])
    query = params[:query]
    operation_name = params[:operationName]
    context = { current_user: user }

    result = FeeeedSchema.execute(query, variables: variables, context: context, operation_name: operation_name)

    track_graphql_event(user: user, query: query, operation_name: operation_name)

    render json: result
  rescue StandardError => e
    raise e unless Rails.env.development?
    handle_error_in_development(e)
  end

  private

  def authenticate_from_bearer
    header = request.headers["Authorization"]
    return nil unless header&.start_with?("Bearer ")
    AppPassword.authenticate(header.delete_prefix("Bearer "))
  end

  # API経路のGraphQLリクエストには visit という概念が無いので、visitなしでイベントだけを記録する。
  # 記録の失敗(DBトラブル等)でGraphQL本体のレスポンスを巻き添えにしないよう`create`を使用する。
  def track_graphql_event(user:, query:, operation_name:)
    parsed = parse_query(query)
    Ahoy::Event.create(
      name: "graphql#execute",
      user_id: user&.id,
      properties: {
        operation_name: operation_name.presence || extract_operation_name(parsed),
        root_fields: extract_root_fields(parsed),
        authenticated: user.present?
      },
      time: Time.current,
    )
  end

  def parse_query(query)
    return nil if query.blank?
    GraphQL.parse(query)
  rescue GraphQL::ParseError
    nil
  end

  def extract_operation_name(parsed)
    return nil if parsed.nil?
    parsed.definitions
      .select { |d| d.is_a?(GraphQL::Language::Nodes::OperationDefinition) }
      .map(&:name)
      .compact
      .first
  end

  def extract_root_fields(parsed)
    return [] if parsed.nil?
    parsed.definitions
      .select { |d| d.is_a?(GraphQL::Language::Nodes::OperationDefinition) }
      .flat_map { |d| d.selections.select { |s| s.respond_to?(:name) }.map(&:name) }
      .uniq
  end

  def prepare_variables(variables_param)
    case variables_param
    when String
      if variables_param.present?
        JSON.parse(variables_param) || {}
      else
        {}
      end
    when Hash
      variables_param
    when ActionController::Parameters
      variables_param.to_unsafe_hash
    when nil
      {}
    else
      raise ArgumentError, "Unexpected parameter: #{variables_param}"
    end
  end

  def handle_error_in_development(e)
    logger.error e.message
    logger.error e.backtrace.join("\n")

    render json: { errors: [ { message: e.message, backtrace: e.backtrace } ], data: {} }, status: 500
  end
end
