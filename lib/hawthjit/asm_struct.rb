module HawthJit
  class AsmStruct
    Member = Struct.new(:offset, :bytesize)
    def self.from_mjit(struct)
      members = struct.new(0).instance_variable_get(:@members)
      members = members.transform_values do |type, offset|
        size =
          case type
          when CType::Stub
            type.size
          when Class
            if CPointer::Pointer > type
              8
            elsif CPointer::Struct > type
              if type.respond_to?(:sizeof)
                type.sizeof
              else
                type.size
              end
            elsif CPointer::Immediate > type
              type.size
            else
              raise "FIXME: unsupported type: #{type}"
            end
          end
        Member.new(offset / 8, size)
      end
      Class.new(AsmStruct) do
        define_singleton_method(:members) { members }
        define_method(:members) { members }
        define_singleton_method(:sizeof) {
          if struct.respond_to?(:sizeof)
            struct.sizeof
          else
            struct.size
          end
        }
      end
    end

    def initialize(reg)
      @reg = reg
    end

    def self.member(name)
      members.fetch(name)
    end

    def self.offset(name)
      member(name).offset
    end

    def [](field)
      member = members.fetch(field)
      AsmJit::X86.ptr(@reg, member.offset, member.bytesize)
    end

    def self.decorate_reg(reg, struct)
      reg.singleton_class.define_method(:[]) do |field|
        struct.new(self)[field]
      end
    end

  end

  # Should this be elsewhere?
  CFPStruct = AsmStruct.from_mjit C.rb_control_frame_t
  ECStruct = AsmStruct.from_mjit C.rb_execution_context_t

  AsmStruct.decorate_reg(AsmJit::X86::REGISTERS[:r13], CFPStruct)
  AsmStruct.decorate_reg(AsmJit::X86::REGISTERS[:r12], ECStruct)
end
