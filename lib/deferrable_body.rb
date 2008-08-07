class DeferrableBody
  include Deferrable
  
  def initialize
    @queue = []
  end
  
  def schedule_dequeue
    return unless @body_callback
    return unless body = @queue.shift
    body.each do |chunk|
      @body_callback.call(chunk)
    end
    schedule_dequeue unless @queue.empty?
  end 

  def call(body)
    @queue << body
    schedule_dequeue
  end

  def each &blk
    @body_callback = blk
    schedule_dequeue
  end

end