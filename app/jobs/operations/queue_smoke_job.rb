module Operations
  class QueueSmokeJob < ApplicationJob
    LOG_MESSAGE = "solid_queue_smoke result=completed".freeze

    def perform
      Rails.logger.info(LOG_MESSAGE)
      LOG_MESSAGE
    end
  end
end
