use crate::{MutSparseArray, MutSparseArrayBase, U32RangeTraits};
use dep::sort::sort_advanced;
unconstrained fn __sort_field_as_u32(lhs: Field, rhs: Field) -> bool {
    lhs as u32 < rhs as u32
}

fn assert_sorted(lhs: Field, rhs: Field) {
    let result = (rhs - lhs - 1);
    result.assert_max_bit_size::<32>();
}

trait RangeTraits {
    fn less_than(lhs: Field, rhs: Field) -> bool;
    fn assert_sorted(lhs: Field, rhs: Field);
    fn assert_greater_than_zero(val: Field);
    fn assert_greater_than_or_equal(lhs: Field, rhs: Field);
}

impl RangeTraits for U32RangeTraits {
    fn less_than(lhs: Field, rhs: Field) -> bool {
        lhs as u32 < rhs as u32
    }

    fn assert_sorted(lhs: Field, rhs: Field) {
        let result = (rhs - lhs - 1);
        result.assert_max_bit_size::<32>();
    }

    fn assert_greater_than_zero(val: Field) {
        val.assert_max_bit_size::<32>();
    }

    fn assert_greater_than_or_equal(lhs: Field, rhs: Field) {
        (lhs - rhs).assert_max_bit_size::<32>();
    }
}

struct FieldComparisonFuncs {}

impl RangeTraits for FieldComparisonFuncs {
    fn less_than(lhs: Field, rhs: Field) -> bool {
        lhs.lt(rhs)
    }

    fn assert_sorted(lhs: Field, rhs: Field) {
        let result = (rhs - lhs - 1);
        result.assert_max_bit_size::<32>();
    }

    fn assert_greater_than_zero(val: Field) {
        val.assert_max_bit_size::<32>();
    }

    fn assert_greater_than_or_equal(lhs: Field, rhs: Field) {
        (lhs - rhs).assert_max_bit_size::<32>();
    }
}

impl<let N: u32, T, ComparisonFuncs> MutSparseArrayBase<N, T, ComparisonFuncs>
where
    T: std::default::Default,
    ComparisonFuncs: RangeTraits,
{

    pub(crate) fn create<let M: u32>(_keys: [Field; M], _values: [T; M], size: Field) -> Self {
        assert(M <= N);
        let _maximum = size - 1;
        let mut r: Self = MutSparseArrayBase {
            keys: [0; N + 2],
            values: [T::default(); N + 3],
            linked_keys: [0; N + 2],
            maximum: _maximum,
            tail_ptr: 0,
        };

        // for any valid index, we want to ensure the following is satified:
        // self.keys[X] <= index <= self.keys[X+1]
        // this requires us to sort hte keys, and insert a startpoint and endpoint
        let sorted_keys = sort_advanced(_keys, __sort_field_as_u32, assert_sorted);

        // insert start and endpoints
        r.keys[0] = 0;
        for i in 0..M {
            r.keys[i + 1] = sorted_keys.sorted[i];
        }
        r.keys[M + 1] = _maximum;

        for i in 0..M + 2 {
            r.linked_keys[i] = i as Field + 1;
        }
        r.linked_keys[M + 1] = -1;

        // populate values based on the sorted keys
        // note: self.keys[i] maps to self.values[i+1]
        // self.values[0] does not map to any key. we use it to store the default empty value,
        // which is returned when `get(idx)` is called and `idx` does not exist in `self.keys`
        for i in 0..M {
            r.values[i + 2] = _values[sorted_keys.sort_indices[i]];
        }
        // insert values that map to our key start and endpoints
        // if _keys[0] = 0 then values[0] must equal _values[0], so some conditional logic is required
        // (same for _keys[N-1])
        let mut initial_value = T::default();
        if (_keys[0] == 0) {
            initial_value = _values[0];
        }
        let mut final_value = T::default();
        if (_keys[M - 1] == _maximum) {
            final_value = _values[M - 1];
        }
        r.values[1] = initial_value;
        r.values[M + 2] = final_value;

        // perform boundary checks!
        // the maximum size of the sparse array is 2^32
        // we need to check that every element in `self.keys` is less than 2^32
        // because `self.keys` is sorted, we can simply validate that
        // sorted_keys.sorted[0] < 2^32
        // sorted_keys.sorted[N-1] < maximum
        ComparisonFuncs::assert_greater_than_or_equal(sorted_keys.sorted[0], 0);
        ComparisonFuncs::assert_greater_than_or_equal(_maximum, 0);
        ComparisonFuncs::assert_greater_than_or_equal(_maximum, sorted_keys.sorted[M - 1]);

        // _maximum.assert_max_bit_size::<32>();
        // (_maximum - sorted_keys.sorted[M - 1]).assert_max_bit_size::<32>();
        r.tail_ptr = M as Field + 2;
        r
    }

    unconstrained fn search_for_key(self, target: Field) -> (Field, Field) {
        let mut found = false;
        let mut found_index = 0;
        let mut previous_less_than_or_equal_to_target = false;
        let mut iterator = 0; // first entry is always smallest
        let mut prev = 0;
        for _ in 0..self.tail_ptr as u32 {
            let current_less_than_or_equal_to_target = self.keys[iterator] as u64 <= target as u64;
            if (self.keys[iterator] == target) {
                found = true;
                found_index = iterator as Field;
                break;
            }
            if (previous_less_than_or_equal_to_target & !current_less_than_or_equal_to_target) {
                found_index = prev as Field;
                break;
            }
            previous_less_than_or_equal_to_target = current_less_than_or_equal_to_target;
            prev = iterator;
            iterator = self.linked_keys[iterator] as u32;
            //    }
        }

        (found as Field, found_index)
    }

    unconstrained fn __check_if_can_insert(self, found: Field) {
        assert(
            (found == 1) | (self.tail_ptr as u32 < N + 2),
            "MutSparseArray::set exceeded maximum size of array",
        );
    }

    fn set(&mut self, idx: Field, value: T) {
        let (found, found_index) = unsafe { self.search_for_key(idx) };
        assert(found * found == found);

        // check can be unsafe because, if check fails, unsatisfiable constraints are created
        // due to an array overflow when accesing `self.linked_keys[self.tail_ptr]`
        unsafe { self.__check_if_can_insert(found) };

        let lhs_index = found_index;
        let rhs_index = self.linked_keys[found_index];

        assert(found * found == found);

        // OK! So we have the following cases to check
        // 1. if `found` then `self.keys[found_index] == idx`
        // 2. if `!found` then `self.keys[found_index] < idx < self.keys[found_index + 1]
        // how do we simplify these checks?
        // case 1 can be converted to `self.keys[found_index] <= idx <= self.keys[found_index]
        // case 2 can be modified to  `self.keys[found_index] + 1 <= idx <= self.keys[found_index + 1] - 1
        // combine the two into the following single statement:
        // `self.keys[found_index] + 1 - found <= idx <= self.keys[found_index + 1 - found] - 1 + found
        let lhs = self.keys[lhs_index];
        let rhs = self.keys[rhs_index];
        let lhs_condition = idx - lhs - 1 + found;
        let rhs_condition = rhs - 1 + found - idx;
        ComparisonFuncs::assert_greater_than_or_equal(lhs_condition, 0);
        ComparisonFuncs::assert_greater_than_or_equal(rhs_condition, 0);

        // lhs_condition.assert_max_bit_size::<32>();
        // rhs_condition.assert_max_bit_size::<32>();
        // lhs points to tail_ptr
        // tail_ptr points to rhs
        if (found == 0) {
            self.keys[self.tail_ptr] = idx;

            self.linked_keys[found_index] = self.tail_ptr * (1 - found) + found * rhs_index;

            self.linked_keys[self.tail_ptr] = rhs_index * (1 - found);
            self.values[self.tail_ptr + 1] = value;
            self.tail_ptr += 1;
        } else {
            self.values[found_index + 1] = value;
        }
    }

    fn get(self, idx: Field) -> T {
        let (found, found_index) = unsafe { self.search_for_key(idx) };
        // println(f"f {found} fi {found_index}");
        assert(found * found == found);

        let lhs_index = found_index;
        let rhs_index = self.linked_keys[found_index];

        assert(found * found == found);

        // OK! So we have the following cases to check
        // 1. if `found` then `self.keys[found_index] == idx`
        // 2. if `!found` then `self.keys[found_index] < idx < self.keys[found_index + 1]
        // how do we simplify these checks?
        // case 1 can be converted to `self.keys[found_index] <= idx <= self.keys[found_index]
        // case 2 can be modified to  `self.keys[found_index] + 1 <= idx <= self.keys[found_index + 1] - 1
        // combine the two into the following single statement:
        // `self.keys[found_index] + 1 - found <= idx <= self.keys[found_index + 1 - found] - 1 + found
        let lhs = self.keys[lhs_index];
        let rhs = self.keys[rhs_index];
        let lhs_condition = idx - lhs - 1 + found;
        let rhs_condition = rhs - 1 + found - idx;
        ComparisonFuncs::assert_greater_than_or_equal(lhs_condition, 0);
        ComparisonFuncs::assert_greater_than_or_equal(rhs_condition, 0);

        // lhs_condition.assert_max_bit_size::<32>();
        // rhs_condition.assert_max_bit_size::<32>();
        let value_index = (lhs_index + 1) * found;
        self.values[value_index]
    }
}

impl<let N: u32, T> MutSparseArray<N, T>
where
    T: std::default::Default,
{
    pub(crate) fn create<let M: u32>(_keys: [Field; M], _values: [T; M], size: Field) -> Self {
        Self { inner: MutSparseArrayBase::create(_keys, _values, size) }
    }

    fn get(self, idx: Field) -> T {
        self.inner.get(idx)
    }

    fn set(&mut self, idx: Field, value: T) {
        self.inner.set(idx, value);
    }

    fn length(self) -> Field {
        self.inner.maximum + 1
    }
}
mod test {

    use crate::MutSparseArray;
    #[test]
    fn test_sparse_lookup() {
        let mut example: MutSparseArray<5, Field> =
            MutSparseArray::create([1, 99, 7, 5], [123, 101112, 789, 456], 100);

        assert(example.get(1) == 123);
        assert(example.get(5) == 456);
        assert(example.get(7) == 789);
        assert(example.get(99) == 101112);

        example.set(55, 222);
        assert(example.get(55) == 222);
        example.set(55, 333);
        assert(example.get(55) == 333);
        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 55) & (i != 99)) {
                assert(example.get(i as Field) == 0);
            }
        }
    }
    #[test]
    fn test_sparse_lookup_boundary_cases() {
        // what about when keys[0] = 0 and keys[N-1] = 2^32 - 1?
        let example: MutSparseArray<6, _> = MutSparseArray::create(
            [0, 99999, 7, 0xffffffff],
            [123, 101112, 789, 456],
            0x100000000,
        );

        assert(example.get(0) == 123);
        assert(example.get(99999) == 101112);
        assert(example.get(7) == 789);
        assert(example.get(0xffffffff) == 456);
        assert(example.get(0xfffffffe) == 0);
    }

    #[test]
    fn test_overwrite_in_a_full_array_succeeds() {
        let mut example: MutSparseArray<4, _> =
            MutSparseArray::create([1, 5, 7, 99999], [123, 456, 789, 101112], 100000);
        assert(example.get(5) == 456);
        example.set(5, 444);
        assert(example.get(5) == 444);
    }

    #[test(should_fail_with = "MutSparseArray::set exceeded maximum size of array")]
    fn test_insert_beyond_maximum_fails() {
        let mut example: MutSparseArray<4, _> =
            MutSparseArray::create([1, 5, 7, 99999], [123, 456, 789, 101112], 100000);
        example.set(11, 444);
        assert(example.get(100000) == 0);
    }

    #[test(should_fail_with = "call to assert_max_bit_size")]
    fn test_sparse_lookup_overflow() {
        let example: MutSparseArray<8, _> =
            MutSparseArray::create([1, 5, 7, 99999], [123, 456, 789, 101112], 100000);

        assert(example.get(100000) == 0);
    }

    #[test(should_fail_with = "call to assert_max_bit_size")]
    fn test_sparse_lookup_boundary_case_overflow() {
        let example: MutSparseArray<4, _> =
            MutSparseArray::create([0, 5, 7, 0xffffffff], [123, 456, 789, 101112], 0x100000000);

        assert(example.get(0x100000000) == 0);
    }

    #[test(should_fail_with = "call to assert_max_bit_size")]
    fn test_sparse_lookup_key_exceeds_maximum() {
        let example: MutSparseArray<6, _> =
            MutSparseArray::create([0, 5, 7, 0xffffffff], [123, 456, 789, 101112], 0xffffffff);
        assert(example.length() == 0xffffffff);
    }
    #[test]
    fn test_sparse_lookup_u32() {
        let example: MutSparseArray<8, _> = MutSparseArray::create(
            [1, 99, 7, 5],
            [123 as u32, 101112 as u32, 789 as u32, 456 as u32],
            100,
        );

        assert(example.get(1) == 123);
        assert(example.get(5) == 456);
        assert(example.get(7) == 789);
        assert(example.get(99) == 101112);

        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i as Field) == 0);
            }
        }
    }

    struct F {
        foo: [Field; 3],
    }
    impl std::cmp::Eq for F {
        fn eq(self, other: Self) -> bool {
            self.foo == other.foo
        }
    }

    impl std::default::Default for F {
        fn default() -> Self {
            F { foo: [0; 3] }
        }
    }

    #[test]
    fn test_sparse_lookup_struct() {
        let values = [
            F { foo: [1, 2, 3] },
            F { foo: [4, 5, 6] },
            F { foo: [7, 8, 9] },
            F { foo: [10, 11, 12] },
        ];
        let example: MutSparseArray<5, _> = MutSparseArray::create([1, 99, 7, 5], values, 100000);

        assert(example.get(1) == values[0]);
        assert(example.get(5) == values[3]);
        assert(example.get(7) == values[2]);
        assert(example.get(99) == values[1]);
        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i as Field) == F::default());
            }
        }
    }
}
