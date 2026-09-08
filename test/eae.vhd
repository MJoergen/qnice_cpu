----------------------------------------------------------------------------------
-- EAE - Extended Arithmetic Element inspired by the PDP-11
--
-- performs 32-bit signed/unsigned integer multiplication and division and modulo
--
-- meant to be connected to a Wishbone Master
--
-- It seems, that on a Xilinx/Artix-7 FPGA, the EAE can be synthesized in a way,
-- that all operations are purely combinatorial: The multiplication is done by
-- the DSP element and the division is creating a huge net, that takes about
-- 3 to 4 clock cycles @ 50 MHz (about 30..40ns) to settle.

-- done in May 2016, improved in October 2016 by sy2002
-- Refactored in September 2026 by MJoergen.
----------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity eae is
   generic (
      -- G_DELAY controls the number of clock cycles to stall the next request.
      -- It accounts for the combinational delay.
      G_DELAY : positive
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;

      -- Wishbone Slave interface
      cyc_i     : in  std_logic;
      stb_i     : in  std_logic;
      stall_o   : out std_logic;
      addr_i    : in  std_logic_vector(2 downto 0);
      we_i      : in  std_logic;
      wr_data_i : in  std_logic_vector(15 downto 0);
      ack_o     : out std_logic;
      rd_data_o : out std_logic_vector(15 downto 0)
   );
end entity eae;

architecture rtl of eae is

   -- EAE register
   constant C_REG_OP0 : std_logic_vector(2 downto 0)  := "000"; -- 16-bit input operand 0
   constant C_REG_OP1 : std_logic_vector(2 downto 0)  := "001"; -- 16-bit input operand 1
   constant C_REG_RLO : std_logic_vector(2 downto 0)  := "010"; -- low word of 32-bit result
   constant C_REG_RHI : std_logic_vector(2 downto 0)  := "011"; -- high word of 32-bit result
   constant C_REG_CSR : std_logic_vector(2 downto 0)  := "100"; -- control and status register

   -- EAE opcodes
   constant C_EAE_MULU : std_logic_vector(1 downto 0) := "00";  -- unsigned multiply
   constant C_EAE_MULS : std_logic_vector(1 downto 0) := "01";  -- signed multiply
   constant C_EAE_DIVU : std_logic_vector(1 downto 0) := "10";  -- unsigned division
   constant C_EAE_DIVS : std_logic_vector(1 downto 0) := "11";  -- signed division

   -- internal registers
   signal op0   : std_logic_vector(15 downto 0);             -- operand 0: the real flip-flop
   signal op0_s : signed(15 downto 0);                       -- operand 0: signed representation
   signal op0_u : unsigned(15 downto 0);                     -- operand 0: unsigned representation
   signal op1   : std_logic_vector(15 downto 0);             -- ditto operand 1
   signal op1_s : signed(15 downto 0);
   signal op1_u : unsigned(15 downto 0);
   signal res   : std_logic_vector(31 downto 0);             -- result: 32-bit flip-flop
   signal csr   : std_logic_vector(1 downto 0);              -- control and status register

   signal stall : std_logic_vector(G_DELAY - 1 downto 0);

begin

   -- Only reads are stalled, not writes
   stall_o <= stall(stall'left) and cyc_i and stb_i and not we_i;

   p_write : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- Shift towards the MSB that stall_o uses.
         stall <= stall(stall'left - 1 downto 0) & '0';

         if cyc_i = '1' and stb_i = '1' and stall_o = '0' and we_i = '1' then

            case addr_i is

               when C_REG_OP0 =>
                  op0   <= wr_data_i;
                  stall <= (others => '1');

               when C_REG_OP1 =>
                  op1   <= wr_data_i;
                  stall <= (others => '1');

               when C_REG_CSR =>
                  csr   <= wr_data_i(1 downto 0);
                  stall <= (others => '1');

               when others =>
                  null;

            end case;

         end if;

         if rst_i = '1' then
            stall <= (others => '0');
            op0   <= (others => '0');
            op1   <= (others => '0');
            csr   <= (others => '0');
         end if;
      end if;
   end process p_write;


   p_ack : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ack_o <= '0';
         if cyc_i = '1' and stb_i = '1' and stall_o = '0' then
            ack_o <= '1';
         end if;
         if rst_i = '1' then
            ack_o <= '0';
         end if;
      end if;
   end process p_ack;


   p_read : process (clk_i)
   begin
      if rising_edge(clk_i) then

         if cyc_i = '1' and stb_i = '1' and stall_o = '0' then
            rd_data_o <= (others => '0');

            if we_i = '0' then
               case addr_i is

                  when C_REG_OP0 =>
                     rd_data_o <= op0;

                  when C_REG_OP1 =>
                     rd_data_o <= op1;

                  when C_REG_RLO =>
                     rd_data_o <= res(15 downto 0);

                  when C_REG_RHI =>
                     rd_data_o <= res(31 downto 16);

                  when C_REG_CSR =>
                     rd_data_o <= "00000000000000" & csr(1 downto 0);

                  when others =>
                     null;

               end case;

            end if;
         end if;
      end if;
   end process p_read;

   p_eae : process (clk_i)
   begin
      if rising_edge(clk_i) then

         case csr is

            when C_EAE_MULU =>
               res <= std_logic_vector(op0_u * op1_u);

            when C_EAE_MULS =>
               res <= std_logic_vector(op0_s * op1_s);

            when C_EAE_DIVU =>
               if op1_u /= 0 then
                  res(15 downto 0)  <= std_logic_vector(op0_u / op1_u);
                  res(31 downto 16) <= std_logic_vector(op0_u mod op1_u);
               end if;

            when C_EAE_DIVS =>
               if op1_s /= 0 then
                  res(15 downto 0)  <= std_logic_vector(op0_s / op1_s);
                  res(31 downto 16) <= std_logic_vector(op0_s mod op1_s);
               end if;

            when others =>
               res <= (others => '0');

         end case;

         if rst_i = '1' then
            res <= (others => '0');
         end if;
      end if;
   end process p_eae;

   op0_s <= signed(op0);
   op0_u <= unsigned(op0);
   op1_s <= signed(op1);
   op1_u <= unsigned(op1);

end architecture rtl;

