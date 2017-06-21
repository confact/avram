abstract class LuckyRecord::Type
  def self.deserialize(value)
    cast(value).as(SuccessfulCast).value
  end

  def self.cast(value : Nil)
    SuccessfulCast(Nil).new(nil)
  end

  def self.cast(value : String)
    SuccessfulCast(String).new(value)
  end

  def self.serialize(value : Nil)
    nil
  end

  def self.serialize(value : String)
    value
  end

  class SuccessfulCast(T)
    getter :value

    def initialize(@value : T)
    end
  end

  class FailedCast
  end
end