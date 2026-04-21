import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';

class Employee {
  Employee(this.id, this.name, this.designation, this.salary);
  final int id;
  final String name;
  final String designation;
  final int salary;
}

class EmployeeDataSource extends DataGridSource {
  EmployeeDataSource({required List<Employee> employeeData, required this.textColor}) {
    _employeeData = employeeData
        .map<DataGridRow>((e) => DataGridRow(cells: [
              DataGridCell<int>(columnName: 'id', value: e.id),
              DataGridCell<String>(columnName: 'name', value: e.name),
              DataGridCell<String>(
                  columnName: 'designation', value: e.designation),
              DataGridCell<int>(columnName: 'salary', value: e.salary),
            ]))
        .toList();
  }

  final Color textColor;
  List<DataGridRow> _employeeData = [];

  @override
  List<DataGridRow> get rows => _employeeData;

  @override
  DataGridRowAdapter buildRow(DataGridRow row) {
    return DataGridRowAdapter(
        cells: row.getCells().map<Widget>((e) {
      return Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          e.value.toString(),
          style: GoogleFonts.inter(color: textColor, fontSize: 13),
        ),
      );
    }).toList());
  }
}

/// Spreadsheet grid pane.
///
/// Currently displays hardcoded placeholder data to demonstrate the grid
/// layout. Replace [_employees] with real data when a data source is wired up.
class ExcelGridPane extends StatefulWidget {
  const ExcelGridPane({super.key});

  @override
  State<ExcelGridPane> createState() => _ExcelGridPaneState();
}

class _ExcelGridPaneState extends State<ExcelGridPane> {
  EmployeeDataSource? employeeDataSource;

  // TODO: Replace with real data source — this is placeholder/demo data.
  final List<Employee> _employees = [
    Employee(10001, 'James', 'Project Lead', 20000),
    Employee(10002, 'Kathryn', 'Manager', 30000),
    Employee(10003, 'Lara', 'Developer', 15000),
    Employee(10004, 'Michael', 'Designer', 15000),
    Employee(10005, 'Martin', 'Developer', 15000),
    Employee(10006, 'Newberry', 'Developer', 15000),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.colors;
    employeeDataSource = EmployeeDataSource(
      employeeData: _employees,
      textColor: c.textMuted,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (employeeDataSource == null || _employees.isEmpty) {
      return Center(
        child: Text(
          'No spreadsheet data loaded',
          style: GoogleFonts.inter(color: c.textMuted, fontSize: 13),
        ),
      );
    }
    return Container(
      color: c.bg,
      child: Column(
        children: [
          Container(
            height: 40,
            color: c.surface,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.bg,
                    border: Border(top: BorderSide(color: c.green, width: 2))
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.table_chart, size: 14, color: c.green),
                      const SizedBox(width: 8),
                      Text("employees.csv", style: GoogleFonts.inter(fontSize: 13, color: c.textMuted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SfDataGrid(
              source: employeeDataSource!,
              columnWidthMode: ColumnWidthMode.fill,
              gridLinesVisibility: GridLinesVisibility.both,
              headerGridLinesVisibility: GridLinesVisibility.both,
              columns: <GridColumn>[
                GridColumn(
                    columnName: 'id',
                    label: Container(
                        padding: const EdgeInsets.all(16.0),
                        alignment: Alignment.centerLeft,
                        color: c.surface,
                        child: Text(
                          'ID',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: c.textBright),
                        ))),
                GridColumn(
                    columnName: 'name',
                    label: Container(
                        padding: const EdgeInsets.all(16.0),
                        alignment: Alignment.centerLeft,
                        color: c.surface,
                        child: Text(
                          'Name',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: c.textBright),
                        ))),
                GridColumn(
                    columnName: 'designation',
                    label: Container(
                        padding: const EdgeInsets.all(16.0),
                        alignment: Alignment.centerLeft,
                        color: c.surface,
                        child: Text(
                          'Designation',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: c.textBright),
                        ))),
                GridColumn(
                    columnName: 'salary',
                    label: Container(
                        padding: const EdgeInsets.all(16.0),
                        alignment: Alignment.centerLeft,
                        color: c.surface,
                        child: Text(
                          'Salary',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: c.textBright),
                        ))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
