module Billing
  class StripeWebhookProcessor
    STRIPE_PROVIDER = BillingWebhookEvent::STRIPE_PROVIDER
    SUBSCRIPTION_LIFECYCLE_EVENT_TYPES = %w[
      customer.subscription.created
      customer.subscription.updated
    ].freeze
    PROCESSED_EVENT_TYPES = %w[
      checkout.session.completed
    ].concat(SUBSCRIPTION_LIFECYCLE_EVENT_TYPES).freeze
    DEFERRED_EVENT_TYPES = %w[
      customer.subscription.deleted
      invoice.paid
      invoice.payment_failed
      invoice.payment_succeeded
    ].freeze

    Result = Struct.new(:success?, :billing_webhook_event, :duplicate?, keyword_init: true)

    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      process_or_acknowledge(find_or_create_receipt)
    rescue ActiveRecord::RecordNotUnique
      process_or_acknowledge(find_existing_receipt)
    rescue StandardError => error
      mark_failed(error)
      Rails.logger.error(
        "Stripe webhook processing failed provider=stripe event_id=#{event_id.inspect} " \
        "event_type=#{event_type.inspect} error=#{error.class.name}"
      )
      Result.new(success?: false, billing_webhook_event: @billing_webhook_event, duplicate?: false)
    end

    private

    attr_reader :event

    def find_or_create_receipt
      existing_receipt = BillingWebhookEvent.find_by(provider: STRIPE_PROVIDER, external_event_id: event_id)
      return @billing_webhook_event = existing_receipt if existing_receipt

      @billing_webhook_event = BillingWebhookEvent.create!(
        provider: STRIPE_PROVIDER,
        external_event_id: event_id,
        event_type: event_type,
        livemode: livemode,
        api_version: api_version,
        status: "received"
      )
    end

    def process_or_acknowledge(billing_webhook_event)
      @billing_webhook_event = billing_webhook_event
      return success_result(billing_webhook_event, duplicate: true) if billing_webhook_event.completed?

      prepare_supported_event!

      billing_webhook_event.with_lock do
        @billing_webhook_event = billing_webhook_event
        return success_result(billing_webhook_event, duplicate: true) if billing_webhook_event.completed?

        process_event!(billing_webhook_event)
        success_result(billing_webhook_event)
      end
    rescue StripeWebhookAssociationError => error
      acknowledge_invalid_association(billing_webhook_event, error)
    end

    def process_event!(billing_webhook_event)
      if PROCESSED_EVENT_TYPES.include?(event_type)
        process_supported_event!(billing_webhook_event)
      else
        ignore_event!(billing_webhook_event)
      end
    rescue StripeWebhookAssociationError => error
      billing_webhook_event.mark_ignored!
      log_invalid_association(error)
    end

    def process_supported_event!(billing_webhook_event)
      case event_type
      when "checkout.session.completed"
        StripeCheckoutCompletionSynchronizer.call(event.data.object)
      when "customer.subscription.created", "customer.subscription.updated"
        @stripe_subscription_synchronizer.call
      end

      billing_webhook_event.mark_processed!
      Rails.logger.info(
        "Stripe webhook processed event_id=#{event_id} event_type=#{event_type} livemode=#{livemode}"
      )
    end

    def ignore_event!(billing_webhook_event)
      ignore_reason = DEFERRED_EVENT_TYPES.include?(event_type) ? "deferred" : "unknown"
      billing_webhook_event.mark_ignored!

      Rails.logger.info(
        "Stripe webhook ignored reason=#{ignore_reason} event_id=#{event_id} " \
        "event_type=#{event_type} livemode=#{livemode}"
      )
    end

    def prepare_supported_event!
      return unless SUBSCRIPTION_LIFECYCLE_EVENT_TYPES.include?(event_type)

      @stripe_subscription_synchronizer = StripeSubscriptionSynchronizer.prepare(event)
    end

    def acknowledge_invalid_association(billing_webhook_event, error)
      billing_webhook_event.with_lock do
        return success_result(billing_webhook_event, duplicate: true) if billing_webhook_event.completed?

        billing_webhook_event.mark_ignored!
        log_invalid_association(error)
        success_result(billing_webhook_event)
      end
    end

    def log_invalid_association(error)
      Rails.logger.info(
        "Stripe webhook ignored reason=invalid_association association_code=#{error.code} event_id=#{event_id} " \
        "event_type=#{event_type} livemode=#{livemode}"
      )
    end

    def mark_failed(error)
      return unless @billing_webhook_event&.persisted?

      @billing_webhook_event.with_lock do
        return if @billing_webhook_event.completed?

        @billing_webhook_event.mark_failed!(error_code: error.class.name.demodulize)
      end
    rescue StandardError => update_error
      Rails.logger.error(
        "Stripe webhook failure status update failed provider=stripe event_id=#{event_id.inspect} " \
        "error=#{update_error.class.name}"
      )
    end

    def find_existing_receipt
      BillingWebhookEvent.find_by!(provider: STRIPE_PROVIDER, external_event_id: event_id)
    end

    def success_result(billing_webhook_event, duplicate: false)
      Result.new(success?: true, billing_webhook_event: billing_webhook_event, duplicate?: duplicate)
    end

    def event_id
      event.id
    end

    def event_type
      event.type
    end

    def livemode
      event.livemode == true
    end

    def api_version
      event.api_version
    end
  end
end
