require "test_helper"

module Operations
  class QueueSmokeJobTest < ActiveJob::TestCase
    test "records a harmless execution marker without arguments" do
      assert_equal QueueSmokeJob::LOG_MESSAGE, QueueSmokeJob.perform_now
      assert_empty QueueSmokeJob.new.arguments
    end
  end
end
