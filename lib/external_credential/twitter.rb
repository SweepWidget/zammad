class ExternalCredential::Twitter

  def self.app_verify(params)
    register_webhook(params)
  end

  def self.request_account_to_link(credentials = {}, app_required = true)
    external_credential = ExternalCredential.find_by(name: 'twitter')
    raise Exceptions::UnprocessableEntity, 'No twitter app configured!' if !external_credential && app_required

    if external_credential
      if credentials[:consumer_key].blank?
        credentials[:consumer_key] = external_credential.credentials['consumer_key']
      end
      if credentials[:consumer_secret].blank?
        credentials[:consumer_secret] = external_credential.credentials['consumer_secret']
      end
    end

    raise Exceptions::UnprocessableEntity, 'No consumer_key param!' if credentials[:consumer_key].blank?
    raise Exceptions::UnprocessableEntity, 'No consumer_secret param!' if credentials[:consumer_secret].blank?

    consumer = OAuth::Consumer.new(
      credentials[:consumer_key],
      credentials[:consumer_secret], {
        site: 'https://api.twitter.com'
      }
    )
    begin
      request_token = consumer.get_request_token(oauth_callback: ExternalCredential.callback_url('twitter'))
    rescue => e
      if e.message == '403 Forbidden'
        raise "#{e.message}, maybe credentials wrong or callback_url for application wrong configured."
      end

      raise e
    end

    {
      request_token: request_token,
      authorize_url: request_token.authorize_url,
    }
  end

  def self.link_account(request_token, params)
    external_credential = ExternalCredential.find_by(name: 'twitter')
    raise Exceptions::UnprocessableEntity, 'No twitter app configured!' if !external_credential

    raise if request_token.params[:oauth_token] != params[:oauth_token]

    access_token = request_token.get_access_token(oauth_verifier: params[:oauth_verifier])
    client = Twitter::REST::Client.new(
      consumer_key: external_credential.credentials[:consumer_key],
      consumer_secret: external_credential.credentials[:consumer_secret],
      access_token: access_token.token,
      access_token_secret: access_token.secret,
    )
    user = client.user

    # check if account already exists
    Channel.where(area: 'Twitter::Account').each do |channel|
      next if !channel.options
      next if !channel.options['user']
      next if !channel.options['user']['id']
      next if channel.options['user']['id'] != user['id']

      # update access_token
      channel.options['auth']['external_credential_id'] = external_credential.id
      channel.options['auth']['oauth_token'] = access_token.token
      channel.options['auth']['oauth_token_secret'] = access_token.secret
      channel.save!

      subscribe_webhook(
        channel:             channel,
        client:              client,
        external_credential: external_credential,
      )

      return channel
    end

    # create channel
    channel = Channel.create!(
      area: 'Twitter::Account',
      options: {
        adapter: 'twitter',
        user: {
          id: user.id,
          screen_name: user.screen_name,
          name: user.name,
        },
        auth: {
          external_credential_id: external_credential.id,
          oauth_token:            access_token.token,
          oauth_token_secret:     access_token.secret,
        },
        sync: {
          limit: 20,
          search: [],
          mentions: {},
          direct_messages: {},
          track_retweets: false
        }
      },
      active: true,
      created_by_id: 1,
      updated_by_id: 1,
    )

    subscribe_webhook(
      channel:             channel,
      client:              client,
      external_credential: external_credential,
    )

    channel
  end

  def self.webhook_url
    "#{Setting.get('http_type')}://#{Setting.get('fqdn')}#{Rails.configuration.api_path}/channels_twitter_webhook"
  end

  def self.register_webhook(params)
    request_account_to_link(params, false)

    raise Exceptions::UnprocessableEntity, 'No consumer_key param!' if params[:consumer_key].blank?
    raise Exceptions::UnprocessableEntity, 'No consumer_secret param!' if params[:consumer_secret].blank?
    raise Exceptions::UnprocessableEntity, 'No oauth_token param!' if params[:oauth_token].blank?
    raise Exceptions::UnprocessableEntity, 'No oauth_token_secret param!' if params[:oauth_token_secret].blank?

    return if params[:env].blank?

    env_name = params[:env]

    client = Twitter::REST::Client.new(
      consumer_key: params[:consumer_key],
      consumer_secret: params[:consumer_secret],
      access_token: params[:oauth_token],
      access_token_secret: params[:oauth_token_secret],
    )

    # needed for verify callback
    Cache.write('external_credential_twitter', {
                  consumer_key: params[:consumer_key],
                  consumer_secret: params[:consumer_secret],
                  access_token: params[:oauth_token],
                  access_token_secret: params[:oauth_token_secret],
                })

    begin
      webhooks = Twitter::REST::Request.new(client, :get, "/1.1/account_activity/all/#{env_name}/webhooks.json", {}).perform
    rescue => e
      begin
        webhooks = Twitter::REST::Request.new(client, :get, '/1.1/account_activity/all/webhooks.json', {}).perform
        raise "Unable to get list of webooks. You use the wrong 'Dev environment label', only #{webhooks.inspect} available."
      rescue => e
        raise "Unable to get list of webooks. Maybe you do not have an Twitter developer approval right now or you use the wrong 'Dev environment label': #{e.message}"
      end
    end
    webhook_id = nil
    webhooks.each do |webhook|
      next if webhook[:url] != webhook_url

      webhook_id = webhook[:id]
    end

    # check if webhook is already registered
    if webhook_id
      params[:webhook_id] = webhook_id
      return params
    end

    # delete already registered webhooks
    webhooks.each do |webhook|
      Twitter::REST::Request.new(client, :delete, "/1.1/account_activity/all/#{env_name}/webhooks/#{webhook[:id]}.json", {}).perform
    end

    # register webhook
    options = {
      url: webhook_url,
    }
    begin
      response = Twitter::REST::Request.new(client, :post, "/1.1/account_activity/all/#{env_name}/webhooks.json", options).perform
    rescue => e
      message = "Unable to register webhook: #{e.message}"
      if %r{http://}.match?(webhook_url)
        message += ' Only https webhooks possible to register.'
      elsif webhooks.count.positive?
        message += " Already #{webhooks.count} webhooks registered. Maybe you need to delete one first."
      end
      raise message
    end

    params[:webhook_id] = response[:id]
    params
  end

  def self.subscribe_webhook(channel:, client:, external_credential:)
    env_name = external_credential.credentials[:env]

    Rails.logger.debug { "Starting Twitter subscription for webhook_id #{webhook_id} and Channel #{channel.id}" }
    begin
      Twitter::REST::Request.new(client, :post, "/1.1/account_activity/all/#{env_name}/subscriptions.json", {}).perform
    rescue => e
      raise "Unable to subscriptions with via webhook: #{e.message}"
    end
  end

end
