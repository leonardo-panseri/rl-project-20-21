library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity project_reti_logiche is
    Port ( i_clk : in std_logic;
           i_rst : in std_logic;
           i_start : in std_logic;
           i_data : in std_logic_vector (7 downto 0);
           o_address : out std_logic_vector (15 downto 0);
           o_done : out std_logic;
           o_en : out std_logic;
           o_we : out std_logic;
           o_data : out std_logic_vector (7 downto 0));
end project_reti_logiche;

architecture FSM of project_reti_logiche is
    -- Custom type for FSM states
    type state_type is ( WAIT_START, READ_COL, CALC_END_ADDR, FIND_MAX_MIN, 
                         CALC_SHIFT_LVL, CALC_NEW_PIXEL, WRITE_NEW_PIXEL, 
                         DONE );
                         
    -- Registers with async reset
    signal current_state: state_type;
    signal read_addr: std_logic_vector (15 downto 0) := (others => '0');
    signal write_addr: std_logic_vector (15 downto 0) := (others => '0');
    signal max_pixel: std_logic_vector (7 downto 0) := (others => '0'); -- Max pixel value in the original image
    signal min_pixel: std_logic_vector (7 downto 0) := (others => '1'); -- Min pixel value in the original image
    signal shift_lvl: std_logic_vector (3 downto 0) := (others => '0'); -- Left shifts needed to calculate the new pixel

    -- Register with sync reset
    -- This register needs a sync reset for performance and area occupation reason
    -- as it is the input of a multiplier
    signal end_addr, next_end_addr: std_logic_vector (15 downto 0) := (others => '0'); -- Original image end address
    
    signal we: std_logic := '0'; -- Control signal for switching between reading and writing from/to test bench RAM
begin
    o_we <= we;
    o_address <= read_addr when we = '0' else -- Multiplexer selecting the right RAM address
                 write_addr;                  -- based on the operation that we are doing
                 
    sync_reg: -- Process handling the register with sync reset
    process(i_clk, i_rst)
    begin
        if rising_edge(i_clk) then -- Updated on the clock rising edge to prevent timing issues with the fsm process
            if i_rst = '1' then
                end_addr <= (others => '0');
            else
                end_addr <= next_end_addr;
            end if;
        end if;
    end process;
    
    fsm: -- Main process handling all the async registers and FSM logic
    process(i_clk, i_rst)
        variable row: std_logic_vector(7 downto 0); -- Intermediate variable for calculating the original image end address
        variable delta_value: unsigned(8 downto 0); -- max_pixel - min_pixel + 1
        variable new_pixel: std_logic_vector(15 downto 0); -- Equalized pixel to write in RAM
    begin
        if i_rst = '1' then
            -- Resetting output signals
            o_done <= '0';
            o_en <= '0';
            we <= '0';
            o_data <= (others => '0');
            
            -- Resetting registers
            read_addr <= (others => '0');
            write_addr <= (others => '0');
            max_pixel <= (others => '0');
            min_pixel <= (others => '1');
            shift_lvl <= (others => '0');
            
            -- Resetting the FSM
            current_state <= WAIT_START;
        elsif falling_edge(i_clk) then -- The FSM is clocked on the falling edge to allow fast read/write to the RAM, that is clocked on the rising edge
            -- Signal assignement to prevent inferred latches
            o_done <= '0';
            o_en <= '0';
            we <= '0';
            o_data <= (others => '0');
            
            -- FSM logic
            case current_state is
                when WAIT_START => -- Waiting for the start signal
                    if i_start = '1' then
                        o_en <= '1';
                        read_addr <= (others => '0');
                        max_pixel <= (others => '0');
                        min_pixel <= (others => '1');
                        current_state <= READ_COL;
                    else
                        current_state <= WAIT_START;
                    end if;
                when READ_COL => -- Reading the first byte containg image width (in bytes)
                    o_en <= '1';
                    
                    next_end_addr <= "00000000" & i_data;
                    
                    read_addr <= std_logic_vector(unsigned(read_addr) + 1);
                    current_state <= CALC_END_ADDR;
                when CALC_END_ADDR => -- Reading the second byte containg image height (in bytes) and calculating image end address
                    o_en <= '1';
                    
                    row := i_data;
                    next_end_addr <= std_logic_vector(unsigned(end_addr(7 downto 0)) * unsigned(row) + 2);
                    
                    read_addr <= std_logic_vector(unsigned(read_addr) + 1);
                    current_state <= FIND_MAX_MIN;
                when FIND_MAX_MIN => -- Looping through all original pixels to find max and min values 
                    o_en <= '1';
                    
                    if unsigned(read_addr) < unsigned(end_addr) then
                        if unsigned(i_data) > unsigned(max_pixel) then
                            max_pixel <= i_data;
                        end if;
                        if unsigned(i_data) < unsigned(min_pixel) then
                            min_pixel <= i_data;
                        end if;
                        
                        current_state <= FIND_MAX_MIN;
                    else
                        current_state <= CALC_SHIFT_LVL;
                    end if;
                    
                    read_addr <= std_logic_vector(unsigned(read_addr) + 1);
                when CALC_SHIFT_LVL => -- Calculating shift level
                    delta_value := unsigned('0' & max_pixel) - unsigned('0' & min_pixel) + 1;
                    if delta_value = 256 then -- The logarithm function is not synthesizable, using threshold checks instead
                        shift_lvl <= "0000";
                    elsif delta_value > 127 then
                        shift_lvl <= "0001";
                    elsif delta_value > 63 then
                        shift_lvl <= "0010";
                    elsif delta_value > 31 then
                        shift_lvl <= "0011";
                    elsif delta_value > 15 then
                        shift_lvl <= "0100";
                    elsif delta_value > 7 then
                        shift_lvl <= "0101";
                    elsif delta_value > 3 then
                        shift_lvl <= "0110";
                    elsif delta_value > 1 then
                        shift_lvl <= "0111";
                    else
                        shift_lvl <= "1000";
                    end if;
                    
                    o_en <= '1';
                    read_addr <= (1 => '1', others => '0');
                    write_addr <= end_addr;
                    current_state <= CALC_NEW_PIXEL;
                when CALC_NEW_PIXEL => -- Calculating equalized pixel value
                    o_en <= '1';
                    
                    if unsigned(read_addr) < unsigned(end_addr) then
                        new_pixel := std_logic_vector(shift_left(unsigned("00000000" & i_data) - 
                                                                    unsigned("00000000" & min_pixel), 
                                                                    to_integer(unsigned(shift_lvl))));
                        -- No simple way to check for shift overflow, using 16 bit register and comparator instead
                        if unsigned(new_pixel) < 256 then
                            o_data <= new_pixel(7 downto 0);
                        else
                            o_data <= (others => '1');
                        end if;
                        
                        read_addr <= std_logic_vector(unsigned(read_addr) + 1);
                        we <= '1';
                        current_state <= WRITE_NEW_PIXEL;
                    else
                        current_state <= DONE;
                    end if;
                when WRITE_NEW_PIXEL => -- Waiting for the write of the calculated pixel and adjusting write address
                    o_en <= '1';
                    
                    write_addr <= std_logic_vector(unsigned(write_addr) + 1);
                    current_state <= CALC_NEW_PIXEL;
                when DONE => -- Equalization done, proceeding with restart procedure
                    if i_start = '1' then
                        o_done <= '1';
                        current_state <= DONE;
                    else
                        o_done <= '0';
                        current_state <= WAIT_START;
                    end if;
            end case;
        end if;
    end process;       
end FSM;